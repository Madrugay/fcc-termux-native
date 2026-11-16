# FCC Termux Native

Ferramentas comunitárias e independentes para preparar e testar a instalação do Free Claude Code (FCC) no **Termux nativo para Android ARM64**.

> **Aviso:** este projeto não é oficial, não é mantido nem endossado pela Anthropic, pelos responsáveis pelo Free Claude Code, pelo Termux ou pelo gRPC. Use por sua conta e risco. Não há garantia de compatibilidade com todos os aparelhos.

## Estado do projeto

**v0.5.0-beta1 — experimental; validação comunitária pendente.**

O instalador foi preparado com base no ambiente de referência descrito no histórico do projeto. Isso não equivale a homologação em outros modelos de celular. A versão beta ainda precisa de testes independentes em aparelhos e instalações limpas antes de ser considerada estável.

## Requisitos desta versão beta

- Termux nativo (não Ubuntu, PRoot ou emulador Linux).
- Android ARM64 / `aarch64`.
- Usuário normal do Termux; não executar como root.
- Python **3.14.10** (a versão está fixada nesta beta).
- Espaço livre e memória suficientes para compilar dependências nativas.

Se o ambiente não corresponder aos requisitos, o instalador deve interromper o processo em vez de tentar adaptar versões incompatíveis.

## Uso

Baixe o arquivo `fcc-termux-native-auto-v0.5.0-beta1.sh` e execute no Termux:

```bash
bash fcc-termux-native-auto-v0.5.0-beta1.sh --check
```

Se a checagem terminar sem erros e você decidir prosseguir:

```bash
bash fcc-termux-native-auto-v0.5.0-beta1.sh --install
```

A instalação pode consumir bastante bateria, RAM, armazenamento e dados. Mantenha o Termux aberto e não interrompa a compilação.

## Proteções implementadas no instalador beta

- Recusa ambientes que não sejam Termux nativo Android ARM64.
- Não substitui uma instalação FCC que já detecte.
- Não executa `pkg upgrade` nem limpa caches.
- Instala somente os grupos de pacotes identificados como ausentes.
- Testa compiladores C e Rust antes da instalação do FCC.
- Só tenta a correção específica de grpcio/c-ares quando identifica a assinatura de erro prevista; cria backup e limita a uma repetição.
- Não tenta corrigir automaticamente erros desconhecidos.
- Gera logs locais para diagnóstico.

**Limitações conhecidas:** a beta fixa versões específicas do FCC e do Python; não oferece ainda a interface completa de diagnóstico/reparo planejada, nem garante que a variável `MATURIN_NO_INSTALL_RUST` resolva todos os cenários de Rust/Maturin no Android. Erros desse tipo devem ser reportados sem aplicar patches improvisados.

## Relatórios de problemas

Ao abrir uma issue, informe:
- modelo do aparelho (opcional), versão do Android e arquitetura;
- versão do Termux;
- resultado de `python --version`, `uv --version`, `clang --version` e `rustc --version`;
- trecho relevante do log, removendo tokens, chaves, URLs privadas e outros dados sensíveis.

Não publique logs completos sem revisá-los antes.

## Licença

Ainda não foi definida uma licença de distribuição. Até que uma licença seja adicionada, não presuma permissões de redistribuição ou reutilização do código.
