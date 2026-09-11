# Contexto do projeto

Este é um fork do [Noveum/hinge](https://github.com/Noveum/hinge), um app de macOS que dobra e desfoca o desktop conforme o ângulo da tampa do MacBook.

## Se o usuário quiser instalar, compilar ou testar o app

Siga o [SETUP.md](SETUP.md). Ele cobre requisitos de hardware, build, instalação e, mais importante, as armadilhas de permissão de Gravação de Tela que não são óbvias e custam bastante tempo quando descobertas na tentativa e erro.

Pontos que costumam derrubar quem instala pela primeira vez, todos detalhados no SETUP.md:

1. Depois de conceder a permissão de tela, o app **precisa** ser encerrado e reaberto. O macOS resolve a autorização uma vez por processo.
2. Build sem identidade de assinatura é ad-hoc, e a permissão fica amarrada ao hash do binário. Todo rebuild a invalida.
3. A seção do certificado auto-assinado é **opcional** e modifica as configurações de confiança do sistema do usuário. Explique o tradeoff e **peça confirmação explícita antes de executar** aquele comando. Nunca rode por conta própria.

## Convenções do repositório

O upstream roda checks rígidos, descritos em [CHECKS.md](CHECKS.md). Ao editar código ou documentação aqui:

- **Sem comentários nem docstrings** em nenhum arquivo de texto versionado
- **Sem travessões** (em dash), literais ou codificados
- Swift segue `swift-format` com `lineLength` 100, config em `.swift-format`
- Mensagens de commit do upstream usam frase imperativa em inglês, sem prefixo Conventional Commits

O design de movimento e as decisões de implementação estão documentados em [MOTION.md](MOTION.md), que deve ser mantido em dia junto com mudanças de comportamento.
