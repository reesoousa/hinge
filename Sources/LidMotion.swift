import Foundation
import QuartzCore

final class LidMotion {
  private let lock = NSLock()
  private var angle: Double?
  private var trackedAngle: Double?
  private var angularVelocity = 0.0
  private var direction = 0
  private var baseline = 0.0
  private var enabled = false
  private var target = 0.0
  private var displayed = 0.0
  private var displayVelocity = 0.0
  private var lastFrame = 0.0
  private var lastSample = 0.0
  private var following = false
  private var settleAngle: Double?
  private var settleStart = 0.0
  private var settling = false
  private var lastTarget = 0.0

  init(openAngle: Double = 100, followOpenAngle: Bool = false) {
    baseline = openAngle
    following = followOpenAngle
  }

  struct Update {
    let availabilityChanged: Bool
    let available: Bool
    let beganClosing: Bool
    let adoptedAngle: Double?
    let adoptionDue: Double?
  }

  func receive(_ value: Double?, at time: Double = CACurrentMediaTime()) -> Update {
    lock.lock()
    defer { lock.unlock() }
    let changed = (angle == nil) != (value == nil)
    let previous = target
    angle = value
    if let value, let trackedAngle, lastSample > 0, time >= lastSample {
      let delta = max(time - lastSample, 0.001)
      let nextAngle = min(max(trackedAngle, value - 0.6), value + 0.6)
      if nextAngle < trackedAngle {
        direction = 1
      } else if nextAngle > trackedAngle {
        direction = -1
      }
      let measuredVelocity = (nextAngle - trackedAngle) / delta
      angularVelocity += (measuredVelocity - angularVelocity) * (1 - exp(-delta / 0.06))
      self.trackedAngle = nextAngle
    } else {
      trackedAngle = value
      angularVelocity = 0
      direction = 0
    }
    lastSample = time
    let adopted = adoptOpenAngle(value, at: time)
    updateTarget(at: time)
    return Update(
      availabilityChanged: changed, available: value != nil,
      beganClosing: previous == 0 && target > 0, adoptedAngle: adopted,
      adoptionDue: adoptionDue(at: time))
  }

  func adoptSettled(at time: Double = CACurrentMediaTime()) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard let angle, let adopted = adoptOpenAngle(angle, at: time) else { return nil }
    updateTarget(at: time)
    return adopted
  }

  private func adoptionDue(at time: Double) -> Double? {
    guard following, let candidate = settleAngle, candidate >= 50, abs(candidate - baseline) > 0.5
    else { return nil }
    return max(settleStart + 0.6 - time, 0)
  }

  private func adoptOpenAngle(_ value: Double?, at time: Double) -> Double? {
    guard following, let value else {
      settleAngle = nil
      return nil
    }
    guard let candidate = settleAngle, abs(value - candidate) <= 1.5 else {
      settleAngle = value
      settleStart = time
      return nil
    }
    guard candidate >= 50, time - settleStart >= 0.6, abs(candidate - baseline) > 0.5
    else { return nil }
    baseline = candidate
    settleStart = time
    return candidate
  }

  func setFollowOpenAngle(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    following = value
    settleAngle = nil
  }

  @discardableResult
  func calibrate() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard let angle, angle >= 25 else { return nil }
    baseline = angle
    reset()
    return baseline
  }

  func setEnabled(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    enabled = value
    reset()
    updateTarget()
    displayed = target
  }

  private func reset() {
    settling = false
    lastTarget = 0
    trackedAngle = angle
    angularVelocity = 0
    direction = 0
    target = 0
    displayed = 0
    displayVelocity = 0
    lastFrame = 0
  }

  private func updateTarget(at time: Double = CACurrentMediaTime()) {
    guard enabled, baseline > 8, let angle, let trackedAngle, angle < baseline else {
      target = 0
      if enabled { direction = -1 }
      return
    }
    let prediction = min(max(velocity(at: time) * 0.035, -0.75), 0.75)
    target = min(max((baseline - 0.6 - trackedAngle - prediction) / (baseline - 8.6), 0), 1)
  }

  func sample(at time: Double = CACurrentMediaTime()) -> Float {
    lock.lock()
    defer { lock.unlock() }
    guard enabled, angle != nil else {
      displayed = 0
      displayVelocity = 0
      settling = false
      return 0
    }
    updateTarget(at: time)
    let elapsed = time - lastFrame
    let delta = lastFrame > 0 && elapsed < 0.1 ? min(max(elapsed, 0), 0.025) : 1.0 / 120
    lastFrame = time
    let frequency = 30 + min(abs(velocity(at: time)) * 0.55, 25)
    let offset = displayed - target
    let previous = displayed
    settling = abs(target - lastTarget) < 0.002
    lastTarget = target
    if settling {
      let energy = min(abs(displayVelocity) / 2.5, 1)
      let damping = max(0.40, 0.96 - 0.46 * energy)
      let springiness = 44.0
      let ringing = springiness * (1 - damping * damping).squareRoot()
      let fade = exp(-damping * springiness * delta)
      let cosine = cos(ringing * delta)
      let sine = sin(ringing * delta)
      let span = (displayVelocity + damping * springiness * offset) / ringing
      displayed = target + fade * (offset * cosine + span * sine)
      displayVelocity =
        fade
        * ((span * ringing - damping * springiness * offset) * cosine
          - (offset * ringing + damping * springiness * span) * sine)
    } else {
      let travel = (displayVelocity + frequency * offset) * delta
      let decay = exp(-frequency * delta)
      displayed = target + (offset + travel) * decay
      displayVelocity = (displayVelocity - frequency * travel) * decay
      if (direction > 0 && displayed < previous) || (direction < 0 && displayed > previous) {
        displayed = previous
        displayVelocity = 0
      }
    }
    let canSettle =
      settling || direction == 0 || (direction > 0 && target >= displayed)
      || (direction < 0 && target <= displayed)
    if canSettle, abs(displayed - target) < 0.00001, abs(displayVelocity) < 0.0001 {
      displayed = target
      displayVelocity = 0
    }
    if displayed < -0.08 || displayed > 1 {
      displayed = min(max(displayed, -0.08), 1)
      displayVelocity = 0
    }
    return Float(displayed)
  }

  private func velocity(at time: Double) -> Double {
    angularVelocity * exp(-max(time - lastSample - 0.12, 0) / 0.08)
  }

  var isClosing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return target > 0 || displayed > 0 || abs(displayVelocity) > 0.0001
  }
}
