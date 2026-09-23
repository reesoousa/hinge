import MetalKit
import ScreenCaptureKit
import SwiftUI

final class ScreenFrames: NSObject, SCStreamOutput, SCStreamDelegate {
  var renderer: DesktopRenderer?
  var onFailure: ((Error) -> Void)?

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: rawStatus) == .complete,
      let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    renderer?.receive(buffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error) }
}

final class DesktopPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class LiveDesktop: NSObject, ObservableObject {
  @Published private(set) var isActive = false
  @Published private(set) var isStarting = false
  @Published private(set) var isWaitingForDisplay = false
  @Published private(set) var sensorAvailable = false
  @Published private(set) var openAngle: Double
  @Published private(set) var effectStrength: Double
  @Published private(set) var followOpenAngle: Bool
  @Published private(set) var pauseCaptureAtRest: Bool
  @Published private(set) var sideFill: SideFill
  @Published private(set) var cropsTop: Bool
  @Published private(set) var blursByDistance: Bool
  @Published private(set) var error: String?
  @Published private(set) var needsPermission = false
  @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: "effectEnabled")
  private static let missingSensorMessage =
    String(
      localized:
        "This Mac doesn't appear to have a lid angle sensor, so Hinge can't follow the lid.")
  private static let sensorDroppedMessage =
    String(
      localized:
        "The lid sensor stopped responding. Hinge turns back on as soon as it reconnects.")
  private let sensor = LidSensor()
  private var sensorMissing = false
  private let motion: LidMotion
  private var stream: SCStream?
  private var frames: ScreenFrames?
  private var renderer: DesktopRenderer?
  private var overlay: NSWindow?
  private var metalView: MTKView?
  private var displayLink: CADisplayLink?
  private var session = UUID()
  private var observers = [NSObjectProtocol]()
  private var resumeAfterWake = false
  private var restoringAtLaunch = UserDefaults.standard.bool(forKey: "effectEnabled")
  private var wakeTask: Task<Void, Never>?
  private var displayTask: Task<Void, Never>?
  private var lastCaptureRecovery = 0.0
  private var capturedDisplayID: CGDirectDisplayID?
  private var includedWindowIDs = Set<CGWindowID>()
  private var captureFilter: SCContentFilter?
  private var captureConfiguration: SCStreamConfiguration?
  private var captureSuspended = false
  private var idleTask: Task<Void, Never>?
  private var resumeTask: Task<Void, Never>?
  private var adoptionTask: Task<Void, Never>?

  override init() {
    let savedAngle = UserDefaults.standard.object(forKey: "openAngle") as? Double ?? 100
    let openAngle = savedAngle.isFinite && (25...180).contains(savedAngle) ? savedAngle : 100
    let savedStrength = UserDefaults.standard.object(forKey: "effectStrength") as? Double ?? 1
    let effectStrength =
      savedStrength.isFinite && (0.25...1).contains(savedStrength) ? savedStrength : 1
    let followOpenAngle = UserDefaults.standard.object(forKey: "followOpenAngle") as? Bool ?? true
    let pauseCaptureAtRest =
      UserDefaults.standard.object(forKey: "pauseCaptureAtRest") as? Bool ?? true
    self.openAngle = openAngle
    self.effectStrength = effectStrength
    self.followOpenAngle = followOpenAngle
    self.pauseCaptureAtRest = pauseCaptureAtRest
    sideFill = UserDefaults.standard.string(forKey: "sideFill").flatMap(SideFill.init) ?? .blur
    cropsTop = UserDefaults.standard.object(forKey: "cropsTop") as? Bool ?? true
    blursByDistance = UserDefaults.standard.object(forKey: "blursByDistance") as? Bool ?? true
    motion = LidMotion(openAngle: openAngle, followOpenAngle: followOpenAngle)
    super.init()
    let motion = motion
    sensor.onAngle = { [weak self] angle in
      let update = motion.receive(angle)
      guard
        update.availabilityChanged || update.beganClosing || update.adoptedAngle != nil
          || update.adoptionDue != nil
      else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        if update.availabilityChanged {
          self.sensorAvailable = update.available
          if update.available, self.sensorMissing {
            self.sensorMissing = false
            if self.error == Self.missingSensorMessage { self.error = nil }
          }
          if !update.available, self.isActive || self.isStarting {
            self.stop()
            self.error = Self.sensorDroppedMessage
          }
        }
        if let adopted = update.adoptedAngle { self.storeOpenAngle(adopted) }
        if let due = update.adoptionDue { self.scheduleAdoption(after: due) }
        if update.beganClosing { self.beginRendering() }
        if update.available, self.isEnabled, !self.isActive, !self.isStarting,
          !self.resumeAfterWake
        {
          let restoring = self.restoringAtLaunch
          self.restoringAtLaunch = false
          await self.start(promptForPermission: !restoring)
        }
      }
    }
    sensor.onMissing = { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.sensorAvailable else { return }
        self.sensorMissing = true
        if self.error == nil { self.error = Self.missingSensorMessage }
      }
    }
    sensor.start()
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.suspendForSleep() }
        })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.resumeFromSleep() }
        })
    }
    observers.append(
      center.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshSpace() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.refreshDisplay() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.refreshIncludedWindows() }
      })
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    restoringAtLaunch = false
    UserDefaults.standard.set(enabled, forKey: "effectEnabled")
    if enabled { Task { await start() } } else { stop() }
  }

  func setOpenPosition() {
    guard let angle = motion.calibrate() else {
      error = String(localized: "Open the lid to your comfortable viewing position first.")
      return
    }
    storeOpenAngle(angle)
    error = nil
    displayLink?.isPaused = true
    metalView?.draw()
  }

  private func scheduleAdoption(after delay: Double) {
    adoptionTask?.cancel()
    adoptionTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay + 0.02)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.adoptionTask = nil
      if let adopted = self.motion.adoptSettled() { self.storeOpenAngle(adopted) }
    }
  }

  private func storeOpenAngle(_ angle: Double) {
    openAngle = angle
    UserDefaults.standard.set(angle, forKey: "openAngle")
  }

  func setFollowOpenAngle(_ value: Bool) {
    guard value != followOpenAngle else { return }
    followOpenAngle = value
    UserDefaults.standard.set(value, forKey: "followOpenAngle")
    motion.setFollowOpenAngle(value)
  }

  func setPauseCaptureAtRest(_ value: Bool) {
    guard value != pauseCaptureAtRest else { return }
    pauseCaptureAtRest = value
    UserDefaults.standard.set(value, forKey: "pauseCaptureAtRest")
    guard isActive else { return }
    if value {
      scheduleIdleSuspend()
    } else {
      idleTask?.cancel()
      idleTask = nil
      resumeCapture()
    }
  }

  func setEffectStrength(_ value: Double) {
    let strength = value.isFinite ? min(max(value, 0.25), 1) : 1
    guard strength != effectStrength else { return }
    effectStrength = strength
    UserDefaults.standard.set(strength, forKey: "effectStrength")
    renderer?.effectStrength = Float(strength)
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
  }

  func setSideFill(_ fill: SideFill) {
    sideFill = fill
    UserDefaults.standard.set(fill.rawValue, forKey: "sideFill")
    renderer?.sideFill = fill
  }

  func setCropsTop(_ enabled: Bool) {
    cropsTop = enabled
    UserDefaults.standard.set(enabled, forKey: "cropsTop")
    renderer?.cropsTop = enabled
  }

  func setBlursByDistance(_ enabled: Bool) {
    blursByDistance = enabled
    UserDefaults.standard.set(enabled, forKey: "blursByDistance")
    renderer?.blursByDistance = enabled
  }

  func start(promptForPermission: Bool = true) async {
    guard !isStarting, !isActive else { return }
    error = nil
    needsPermission = false
    guard sensorAvailable else {
      sensor.reconnect()
      if sensorMissing { error = Self.missingSensorMessage }
      return
    }
    let hasScreenAccess =
      CGPreflightScreenCaptureAccess() || (promptForPermission && CGRequestScreenCaptureAccess())
    guard hasScreenAccess else {
      needsPermission = true
      error = String(
        localized: "Allow Hinge in Screen Recording settings, then quit and reopen it.")
      return
    }
    guard builtInScreenAvailable else {
      isWaitingForDisplay = true
      return
    }
    isWaitingForDisplay = false
    isStarting = true
    sensor.setTracking(true)
    let session = UUID()
    self.session = session
    do {
      let renderer = try DesktopRenderer(resources: .main, motion: motion)
      renderer.effectStrength = Float(effectStrength)
      renderer.sideFill = sideFill
      renderer.cropsTop = cropsTop
      renderer.blursByDistance = blursByDistance
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      guard self.session == session else { return }
      guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == display.displayID
        })
      else {
        stop()
        isWaitingForDisplay = true
        return
      }
      let ownApplications = content.applications.filter {
        $0.processID == ProcessInfo.processInfo.processIdentifier
      }
      let ownWindows = includedWindows(in: content)
      let filter = SCContentFilter(
        display: display, excludingApplications: ownApplications, exceptingWindows: ownWindows)
      capturedDisplayID = display.displayID
      includedWindowIDs = Set(ownWindows.map(\.windowID))
      captureFilter = filter
      let area = screen.frame
      let configuration = SCStreamConfiguration()
      configuration.sourceRect = CGRect(
        x: area.minX - screen.frame.minX, y: screen.frame.maxY - area.maxY, width: area.width,
        height: area.height)
      let scale = min(screen.backingScaleFactor, 2800 / area.width, 1.6)
      configuration.width = Int(area.width * scale) / 2 * 2
      configuration.height = Int(area.height * scale) / 2 * 2
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
      configuration.queueDepth = 3
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false
      configuration.capturesAudio = false
      configuration.colorSpaceName = CGColorSpace.sRGB
      captureConfiguration = configuration
      try await renderer.warmUp(width: configuration.width, height: configuration.height)
      guard self.session == session else { return }
      let frames = ScreenFrames()
      frames.renderer = renderer
      frames.onFailure = { [weak self] failure in
        Task { @MainActor in
          guard let self, self.session == session else { return }
          self.captureStopped(failure)
        }
      }
      let stream = SCStream(filter: filter, configuration: configuration, delegate: frames)
      try stream.addStreamOutput(
        frames, type: .screen,
        sampleHandlerQueue: DispatchQueue(label: "hinge.capture", qos: .userInteractive))
      self.renderer = renderer
      self.frames = frames
      self.stream = stream
      renderer.onPresentation = { [weak self] failure in
        guard let self, self.session == session else { return }
        if let failure {
          self.stop()
          self.error = String(
            localized: "The desktop renderer stopped: \(failure.localizedDescription)")
        }
      }
      renderer.onRest = { [weak self] in self?.restOverlay() }
      makeOverlay(screen: screen, area: area, renderer: renderer)
      try await stream.startCapture()
      guard self.session == session else {
        try? await stream.stopCapture()
        return
      }
      let deadline = CACurrentMediaTime() + 5
      while !renderer.hasFrame {
        guard self.session == session else { return }
        guard CACurrentMediaTime() < deadline else {
          needsPermission = true
          throw DesktopError.message(
            String(
              localized:
                "No desktop frames arrived. Check Screen Recording permission and reopen Hinge."))
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard self.session == session else { return }
      guard sensorAvailable else { throw DesktopError.message(Self.sensorDroppedMessage) }
      motion.setEnabled(true)
      isActive = true
      isStarting = false
      if motion.isClosing {
        renderer.beginEntry()
        beginRendering()
      } else {
        scheduleIdleSuspend()
      }
    } catch {
      guard self.session == session else { return }
      stop()
      if builtInScreenAvailable {
        self.error = error.localizedDescription
      } else {
        isWaitingForDisplay = true
      }
    }
  }

  private var builtInScreenAvailable: Bool {
    NSScreen.screens.contains {
      guard
        let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { return false }
      return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
  }

  private func includedWindows(in content: SCShareableContent) -> [SCWindow] {
    content.windows.filter {
      $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        && $0.windowID != CGWindowID(overlay?.windowNumber ?? 0)
        && $0.title != "Hinge Desktop Overlay"
    }
  }

  private func refreshIncludedWindows() async {
    guard isActive, let stream, let capturedDisplayID else { return }
    let currentSession = session
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)
      guard session == currentSession,
        let display = content.displays.first(where: { $0.displayID == capturedDisplayID })
      else { return }
      let windows = includedWindows(in: content)
      let windowIDs = Set(windows.map(\.windowID))
      guard windowIDs != includedWindowIDs else { return }
      let applications = content.applications.filter {
        $0.processID == ProcessInfo.processInfo.processIdentifier
      }
      let filter = SCContentFilter(
        display: display, excludingApplications: applications, exceptingWindows: windows)
      try await stream.updateContentFilter(filter)
      if session == currentSession {
        includedWindowIDs = windowIDs
        captureFilter = filter
      }
    } catch {
      guard session == currentSession else { return }
      stop()
      self.error = String(
        localized: "Could not update the captured windows: \(error.localizedDescription)")
    }
  }

  private func refreshSpace() {
    guard isActive, !resumeAfterWake else { return }
    displayTask?.cancel()
    let refreshSession = session
    displayTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      guard let self, !Task.isCancelled, self.session == refreshSession,
        self.isActive, !self.resumeAfterWake
      else { return }
      self.displayTask = nil
      guard let displayID = self.capturedDisplayID,
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value == displayID
        })
      else { return }
      if self.overlay?.frame != screen.frame {
        self.stop()
        await self.start()
      } else {
        self.overlay?.orderFrontRegardless()
      }
    }
  }

  private func makeOverlay(screen: NSScreen, area: CGRect, renderer: DesktopRenderer) {
    let window = DesktopPanel(
      contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    window.isFloatingPanel = true
    window.becomesKeyOnlyIfNeeded = true
    window.title = "Hinge Desktop Overlay"
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    window.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false
    window.sharingType = .readOnly
    let view = MTKView(frame: NSRect(origin: .zero, size: area.size), device: renderer.device)
    view.delegate = renderer
    view.colorPixelFormat = .bgra8Unorm
    view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    view.clearColor = MTLClearColorMake(0, 0, 0, 0)
    view.framebufferOnly = true
    view.isPaused = true
    view.enableSetNeedsDisplay = false
    view.autoResizeDrawable = true
    view.layer?.isOpaque = false
    window.contentView = view
    window.setFrame(area, display: false)
    overlay = window
    metalView = view
    window.orderFrontRegardless()
    view.draw()
    let link = view.displayLink(target: self, selector: #selector(drawFrame(_:)))
    let refresh = Float(min(max(screen.maximumFramesPerSecond, 1), 60))
    view.preferredFramesPerSecond = Int(refresh)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: refresh, maximum: refresh, preferred: refresh)
    link.isPaused = true
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func beginRendering() {
    guard isActive, motion.isClosing else { return }
    idleTask?.cancel()
    idleTask = nil
    resumeCapture()
    displayLink?.isPaused = false
  }

  @objc private func drawFrame(_ link: CADisplayLink) {
    guard isActive else { return }
    renderer?.presentationTime = link.targetTimestamp
    metalView?.draw()
  }

  private func captureStopped(_ failure: Error) {
    stop()
    let now = CACurrentMediaTime()
    guard now - lastCaptureRecovery > 5 else {
      error = failure.localizedDescription
      return
    }
    lastCaptureRecovery = now
    isWaitingForDisplay = true
    refreshDisplay(after: .seconds(1))
  }

  private func restOverlay() {
    guard !motion.isClosing else { return }
    displayLink?.isPaused = true
    scheduleIdleSuspend()
  }

  private func scheduleIdleSuspend() {
    guard pauseCaptureAtRest, isActive, !captureSuspended, idleTask == nil, stream != nil
    else { return }
    let idleSession = session
    idleTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, !Task.isCancelled, self.session == idleSession, self.isActive,
        !self.motion.isClosing
      else { return }
      self.idleTask = nil
      await self.refreshIncludedWindows()
      guard self.session == idleSession, self.isActive, !self.motion.isClosing else { return }
      self.suspendCapture()
    }
  }

  private func suspendCapture() {
    guard isActive, !captureSuspended, let stream else { return }
    captureSuspended = true
    let output = frames
    output?.renderer = nil
    output?.onFailure = nil
    self.stream = nil
    frames = nil
    Task {
      try? await stream.stopCapture()
      if let output { try? stream.removeStreamOutput(output, type: .screen) }
    }
  }

  private nonisolated static func startStream(
    filter: SCContentFilter, configuration: SCStreamConfiguration, output: ScreenFrames
  ) async throws -> SCStream {
    let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    try stream.addStreamOutput(
      output, type: .screen,
      sampleHandlerQueue: DispatchQueue(label: "hinge.capture", qos: .userInteractive))
    try await stream.startCapture()
    return stream
  }

  private func resumeCapture() {
    guard isActive, captureSuspended, resumeTask == nil, let renderer,
      let filter = captureFilter, let configuration = captureConfiguration
    else { return }
    let resumeSession = session
    resumeTask = Task { [weak self] in
      guard let self else { return }
      do {
        let output = ScreenFrames()
        output.renderer = renderer
        output.onFailure = { [weak self] failure in
          Task { @MainActor in
            guard let self, self.session == resumeSession else { return }
            self.captureStopped(failure)
          }
        }
        let stream = try await Self.startStream(
          filter: filter, configuration: configuration, output: output)
        self.resumeTask = nil
        guard self.session == resumeSession, self.isActive, self.captureSuspended else {
          output.renderer = nil
          output.onFailure = nil
          try? await stream.stopCapture()
          return
        }
        self.frames = output
        self.stream = stream
        self.captureSuspended = false
      } catch {
        self.resumeTask = nil
        guard self.session == resumeSession, self.isActive else { return }
        self.stop()
        self.error = String(
          localized: "Could not resume desktop capture: \(error.localizedDescription)")
      }
    }
  }

  private func refreshDisplay(after delay: Duration = .milliseconds(300)) {
    guard isActive || isWaitingForDisplay, !resumeAfterWake else { return }
    displayTask?.cancel()
    displayTask = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, self.isActive || self.isWaitingForDisplay, !self.resumeAfterWake else {
        return
      }
      self.displayTask = nil
      self.stop()
      await self.start()
    }
  }

  private func suspendForSleep() {
    resumeAfterWake = resumeAfterWake || isActive || isStarting || isWaitingForDisplay
    stop(preserveResume: true)
    sensor.stop()
  }

  private func resumeFromSleep() {
    guard !isActive, !isStarting, wakeTask == nil else { return }
    sensor.reconnect()
    guard resumeAfterWake else { return }
    wakeTask = Task { [weak self] in
      guard let self else { return }
      for attempt in 0..<100 {
        guard self.resumeAfterWake, !Task.isCancelled else { return }
        if self.sensorAvailable { break }
        if attempt > 0, attempt.isMultiple(of: 20) { self.sensor.reconnect() }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
      guard self.resumeAfterWake, !Task.isCancelled else { return }
      self.wakeTask = nil
      self.resumeAfterWake = false
      await self.start()
    }
  }

  func stop(preserveResume: Bool = false) {
    if !preserveResume {
      resumeAfterWake = false
      wakeTask?.cancel()
      wakeTask = nil
    }
    session = UUID()
    idleTask?.cancel()
    idleTask = nil
    resumeTask?.cancel()
    resumeTask = nil
    captureSuspended = false
    captureFilter = nil
    captureConfiguration = nil
    sensor.setTracking(false)
    motion.setEnabled(false)
    displayLink?.invalidate()
    displayLink = nil
    metalView?.isPaused = true
    metalView?.delegate = nil
    overlay?.orderOut(nil)
    overlay?.close()
    overlay = nil
    metalView = nil
    displayTask?.cancel()
    displayTask = nil
    let oldStream = stream
    let oldFrames = frames
    stream = nil
    if let oldStream {
      Task {
        try? await oldStream.stopCapture()
        if let oldFrames { try? oldStream.removeStreamOutput(oldFrames, type: .screen) }
      }
    }
    frames = nil
    renderer = nil
    capturedDisplayID = nil
    includedWindowIDs = []
    isActive = false
    isStarting = false
    isWaitingForDisplay = false
  }

  func shutDown() {
    stop()
    sensor.stop()
  }
}
