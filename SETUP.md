# Instalar o Hinge Native Edition

Fork do [Noveum/hinge](https://github.com/Noveum/hinge) com cinco mudanças ainda não presentes no upstream:

| Mudança | O que faz |
|---|---|
| Wake recovery | A animação de **abertura** volta a rodar depois de fechar a tampa por completo. No upstream ela nunca aparecia: a recuperação pós-sono esperava 1 segundo fixo antes de checar o sensor, e a tampa já estava aberta. |
| Follow my open angle | A posição aberta passa a ser o ângulo onde você **estaciona** a tampa, toda vez. Onde você deixar a tela, ela fica visível. |
| Pause capture at rest | A captura para 3 s depois que a dobra repousa. O indicador de gravação de tela do macOS deixa de ficar aceso o dia inteiro e passa a acender só durante a dobra. |
| Fade de entrada | Tira o solavanco visível no início da animação de abertura, e remove do caminho crítico o trabalho pesado que travava o começo do efeito. |
| Utilitário de barra de menus | O app roda sem ícone na Dock e sem aparecer no Cmd+Tab. Vive no ícone ao lado do relógio. |

## Requisitos

- MacBook **Apple silicon** com sensor de ângulo de tampa (modelos recentes)
- **macOS 14** ou superior
- Xcode Command Line Tools (não precisa do Xcode completo)

Sem o sensor de tampa o app não funciona. Para conferir antes de investir tempo:

```bash
ioreg -c AppleHIDTransportInterface -r | grep -i "lid angle" || system_profiler SPHardwareDataType | grep -E "Model Identifier|Chip"
```

## Instalação

```bash
xcode-select --install 2>/dev/null
make build
cp -R build/Hinge.app /Applications/
open -a /Applications/Hinge.app
```

Depois, em **Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela**, autorize o Hinge.

**Passo que a maioria pula:** depois de autorizar, **encerre e reabra o app**. O macOS resolve a autorização de captura uma vez por processo, então conceder a permissão com o app já rodando não surte efeito no processo vivo.

```bash
osascript -e 'quit app "Hinge"'; sleep 1; open -a /Applications/Hinge.app
```

## Se a permissão nunca for reconhecida

Sintoma: o app insiste em pedir permissão mesmo com o toggle já ativado em Ajustes.

Causa: `make build` sem identidade de assinatura gera uma assinatura ad-hoc, e para app ad-hoc o macOS amarra a permissão ao **hash exato do binário**. Todo rebuild gera um hash novo, e o registro anterior vira lixo que aponta para um binário que não existe mais. O toggle continua marcado e não vale nada.

Solução imediata:

```bash
osascript -e 'quit app "Hinge"'; pkill -x Hinge; tccutil reset ScreenCapture local.hinge.app; open -a /Applications/Hinge.app
```

Ligue o Hinge, aceite o prompt do sistema, e encerre/reabra.

## Opcional: parar de reconceder a permissão a cada rebuild

Só vale a pena se você for compilar várias versões. Um certificado próprio dá ao app uma identidade estável, e a permissão passa a colar nela em vez de no hash do binário.

**Isto cria um certificado raiz auto-assinado confiável na sua conta, com escopo restrito a assinatura de código, e vai pedir sua senha.** A chave privada é gerada em diretório temporário e apagada em seguida. É o tradeoff padrão de assinatura local de desenvolvimento, mas é uma mudança real de confiança no seu sistema. Se preferir não fazer, o caminho ad-hoc acima funciona.

```bash
D=$(mktemp -d) && openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$D/k.key" -out "$D/c.crt" -subj "/CN=Hinge Local" -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null && openssl pkcs12 -export -inkey "$D/k.key" -in "$D/c.crt" -out "$D/c.p12" -passout pass:hinge -name "Hinge Local" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 && security import "$D/c.p12" -k ~/Library/Keychains/login.keychain-db -P hinge -T /usr/bin/codesign -A && security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$D/c.crt"; rm -rf "$D"; security find-identity -v -p codesigning
```

Duas armadilhas já tratadas no comando acima, para referência:

- O PKCS#12 padrão do OpenSSL 3 usa algoritmos que o Security framework da Apple não lê, e a importação falha com `MAC verification failed`. Por isso os `-certpbe`/`-keypbe`/`-macalg` legados.
- Sem o passo de confiança (`add-trusted-cert`), o `codesign` recusa a identidade com `no identity found`, mesmo com ela importada.

A saída deve terminar com `1 valid identities found` listando `Hinge Local`. A partir daí compile sempre assim:

```bash
SIGN_IDENTITY="Hinge Local" make build && rm -rf /Applications/Hinge.app && cp -R build/Hinge.app /Applications/ && open -a /Applications/Hinge.app
```

Conceda a permissão de tela uma última vez. Depois disso ela sobrevive aos rebuilds.

## Testando as mudanças

| O quê | Como |
|---|---|
| Dobra | Incline a tampa sem fechar por completo. A tela dobra e desfoca progressivamente. |
| Abertura | Feche até o Mac dormir, espere um segundo, abra. A tela deve **desdobrar** na subida, sem solavanco no início. |
| Ângulo adaptativo | Estacione a tampa num ângulo novo e espere um segundo. A tela fica limpa a partir dali; só fechar a partir desse ponto dobra. Segurar a tampa parada no meio de um fechamento **não** deve desfazer a dobra. |
| Pausa de captura | Com a tampa parada por mais de 3 s, o indicador de gravação de tela do macOS apaga. Ele reacende ao mover a tampa. |

O ângulo adaptativo e a pausa de captura têm toggles em **Ajustes** dentro do app, caso você prefira o comportamento antigo.

Como o app não aparece na Dock, abra os Ajustes pelo ícone do Hinge na barra de menus, ao lado do relógio. O atalho **⌃⌥H** liga e desliga o efeito de qualquer lugar.
