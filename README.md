# Hinge Native Edition

Dê uma dobradinha no desktop do seu MacBook. Feche a tampa e veja a tela dobrar e desfocar suavemente. Abra e tudo volta.

Fork do [Noveum/hinge](https://github.com/Noveum/hinge) com quatro mudanças ainda ausentes no upstream e um acabamento de integração com o sistema.

## O que muda neste fork

| Mudança | O que resolve |
|---|---|
| Recuperação pós-sono | A animação de **abertura** volta a rodar depois de fechar a tampa por completo. No upstream ela nunca aparecia: a recuperação esperava 1 segundo fixo antes de checar o sensor, e a tampa já estava aberta quando o app voltava. |
| Segue o ângulo de abertura | A posição aberta passa a ser o ângulo onde você **estaciona** a tampa, toda vez. Onde você deixar a tela, ela fica limpa, e só fechar a partir dali dobra. |
| Pausa de captura em repouso | A captura para 3 segundos depois que a dobra repousa. O indicador de gravação de tela do macOS deixa de ficar aceso o dia inteiro e passa a acender só durante a dobra. |
| Entrada suave | Remove o solavanco visível no início da animação, e tira do caminho crítico o trabalho pesado que travava o começo do efeito. |

Além disso, o app roda como utilitário de barra de menus: sem ícone na Dock, sem aparecer no Cmd+Tab. Ele vive no ícone ao lado do relógio, como um app nativo do sistema.

## Para os curiosos

O Hinge lê o ângulo da tampa 120 vezes por segundo e transforma isso numa animação contínua. Inclinação lenta, dobra lenta. Inclinação rápida, dobra rápida. Uma suavização tira os degraus das leituras do sensor, que vêm em graus inteiros.

O ScreenCaptureKit fornece seu desktop ao vivo, e o Metal aplica perspectiva e desfoque progressivo a 60 fps. Tudo permanece na memória do seu Mac. Sem gravações, sem envio para lugar nenhum.

O indicador de gravação de tela do macOS é desenhado pelo sistema e **nenhum app consegue escondê-lo**. É uma proteção de privacidade, e contorná-la seria derrotar o propósito dela. O que este fork faz é honesto: não captura quando não há nada a capturar.

## Instalação

Requer um MacBook **Apple silicon** com sensor de ângulo de tampa e **macOS 14** ou superior.

O passo a passo completo está no [SETUP.md](SETUP.md), incluindo as armadilhas de permissão de Gravação de Tela que custam bastante tempo quando descobertas na tentativa e erro. O caminho curto:

```sh
make build
cp -R build/Hinge.app /Applications/
open -a /Applications/Hinge.app
```

Depois autorize o app em **Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela**, e então **encerre e reabra o app**. O macOS resolve a autorização de captura uma vez por processo, então conceder a permissão com o app já rodando não surte efeito.

Por padrão o Hinge trata como posição aberta qualquer ângulo onde você estacionar a tampa. Prefere um ângulo fixo? Desligue **Follow my open angle** nos Ajustes, acomode a tela e clique em **Set open position**. O Hinge lembra.

## Design do movimento

As decisões de implementação, os números de temporização e o raciocínio por trás de cada escolha estão em [MOTION.md](MOTION.md), mantido em dia junto com as mudanças de comportamento.

## Créditos

Todo o trabalho original é do [Noveum/hinge](https://github.com/Noveum/hinge). As mudanças deste fork estão propostas de volta ao upstream em pull requests separados.

[Checks e setup de desenvolvimento](CHECKS.md).
