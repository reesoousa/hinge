# Hinge Native Edition

Dê uma dobradinha no desktop do seu MacBook. Feche a tampa e veja a tela dobrar e desfocar suavemente. Abra e tudo volta.

## Por que este fork existe

O upstream entrega o efeito. Este fork persegue outra coisa: fazer o Hinge **parecer parte do sistema**, e não um app que você instalou.

Isso significa sumir quando não é chamado e funcionar sem manutenção. Na prática:

- **Sem ícone na Dock e fora do Cmd+Tab.** Ele vive no ícone ao lado do relógio, como qualquer utilitário nativo de barra de menus.
- **Sem indicador de gravação aceso o dia inteiro.** A captura só roda quando há dobra acontecendo.
- **Sem calibração manual.** A posição aberta é onde você estacionar a tampa, toda vez, sem você pedir.
- **Sem animação pela metade.** Abrir o MacBook depois de fechar por completo volta a animar, com a entrada suavizada.

Um app nativo não te pede atenção. A régua deste fork é essa.

## Inspiração

O Hinge é uma reconstrução do **[Bendy](https://trybendy.app/)**, que fez o efeito primeiro. O [post de lançamento do Bendy](https://x.com/adrianabelarde_/status/2097998552517759106) e o [contexto do Expo Duo](https://x.com/nater02/status/2097776349217771912) são as referências de movimento que o upstream usou para reconstruir a animação a partir de vídeo, quadro a quadro.

Nada de código veio dessas fontes. A geometria da dobra, os níveis de desfoque e a temporização foram derivados de observação e estão documentados com números e raciocínio em [MOTION.md](MOTION.md), incluindo as tentativas que deram errado.

## Especificações

| Requisito | Detalhe |
|---|---|
| Hardware | MacBook **Apple silicon** com sensor de ângulo de tampa |
| Sensor | HID Apple (vendor `0x05AC`), usage page `0x0020`, usage `0x008A` |
| Sistema | **macOS 14.0** ou superior |
| Permissão | Gravação de Tela |
| GPU | Metal (nativo em todo Apple silicon) |
| Para compilar | Xcode Command Line Tools, sem necessidade do Xcode completo |

Sem o sensor de ângulo de tampa o app não funciona, e ele não existe em todos os modelos. Vale conferir antes de investir tempo.

### Como funciona por dentro

| Característica | Valor |
|---|---|
| Leitura do sensor | 120 Hz com o efeito ligado, 10 Hz desligado |
| Renderização | 60 fps, via display link próprio da view |
| Desfoque | 3 níveis gaussianos em cache na GPU, 6 / 16 / 36 px por 786 px de referência |
| Posição aberta padrão | 100 graus, ou o ângulo onde você estacionar a tampa |
| Alvo de compilação | `arm64-apple-macosx14.0` |

O ScreenCaptureKit fornece o desktop ao vivo e o Metal aplica perspectiva e desfoque progressivo. Tudo permanece na memória do seu Mac. Sem gravações, sem envio para lugar nenhum.

O indicador de gravação de tela do macOS é desenhado pelo sistema e **nenhum app consegue escondê-lo**. É uma proteção de privacidade, e contorná-la seria derrotar o propósito dela. O que este fork faz é honesto: não captura quando não há o que capturar.

## O que muda em relação ao upstream

| Mudança | O que resolve |
|---|---|
| Recuperação pós-sono | A animação de **abertura** volta a rodar depois de fechar a tampa por completo. No upstream ela nunca aparecia: a recuperação esperava 1 segundo fixo antes de checar o sensor, e a tampa já estava aberta quando o app voltava. |
| Segue o ângulo de abertura | A posição aberta passa a ser o ângulo onde você estaciona a tampa. Onde você deixar a tela, ela fica limpa, e só fechar a partir dali dobra. |
| Pausa de captura em repouso | A captura para 3 segundos depois que a dobra repousa, e o indicador do sistema acompanha o movimento da tampa em vez de ficar aceso o tempo todo. |
| Entrada suave | Remove o solavanco no início da animação e tira do caminho crítico o trabalho pesado que travava o começo do efeito. |
| Utilitário de barra de menus | Sem ícone na Dock, sem Cmd+Tab. |

As quatro primeiras estão propostas de volta ao upstream em pull requests separados.

## Instalação

O passo a passo completo está no [SETUP.md](SETUP.md), incluindo as armadilhas de permissão de Gravação de Tela que custam bastante tempo quando descobertas na tentativa e erro. O caminho curto:

```sh
make build
cp -R build/Hinge.app /Applications/
open -a /Applications/Hinge.app
```

Depois autorize em **Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela**, e então **encerre e reabra o app**. O macOS resolve a autorização de captura uma vez por processo, então conceder a permissão com o app já rodando não surte efeito.

Como o app não aparece na Dock, os Ajustes se abrem pelo ícone na barra de menus. O atalho **⌃⌥H** liga e desliga o efeito de qualquer lugar.

## Créditos

Todo o trabalho original é do [Noveum/hinge](https://github.com/Noveum/hinge), e o efeito original é do [Bendy](https://trybendy.app/).

[Checks e setup de desenvolvimento](CHECKS.md).
