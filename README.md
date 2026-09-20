# ipa-tweak-bot

Camada pública de **orquestração do IPA Injector**. Este repositório contém os workflows do GitHub Actions que recebem comandos do bot/Worker, baixam o Core privado e a configuração compartilhada, processam um IPA e devolvem o resultado ao Telegram.

A lógica sensível, os tweaks, patches e scripts principais ficam em `Bot-Injector-Core`. Este repositório funciona principalmente como **runner/orquestrador**.

## Arquitetura

```text
Telegram / Worker
       ↓
ipa-tweak-bot
       ├── checkout Bot-Injector-Core
       ├── checkout ipa-shared-config-core
       ↓
GitHub Actions
       ↓
input.ipa
       ↓
injeção / patches / validações
       ↓
Final.ipa
       ↓
Telegram
```

## Estrutura do repositório

| Arquivo | Função |
| --- | --- |
| `.github/workflows/telegram-inject.yml` | Workflow principal do Injector. Baixa o IPA do Telegram, identifica app/addon, aplica injeções e pós-processamentos, valida o IPA final e envia o resultado ao bot. |
| `.github/workflows/healthcheck.yml` | Teste mínimo para confirmar que o runner do Injector/GitHub Actions está disponível. |
| `.github/workflows/build-messenger-name-fix.yml` | Workflow auxiliar de compilação/teste para o patch de nome/comportamento do Messenger. |
| `.github/workflows/get-telegram-translation-channel-id.yml` | Utilitário para descobrir/validar o ID do canal usado pelos arquivos de tradução do Messenger. |
| `.github/workflows/messenger-portuguese.yml` | Workflow de construção e validação do componente de tradução/ajustes do Messenger em português. |
| `README.md` | Esta documentação. |

## `telegram-inject.yml`

É o workflow de produção do Injector.

### Entradas

- `addon`: permite escolher um addon/tweak específico; vazio usa o padrão configurado.
- `telegram_message_id`: ID da mensagem temporária usada para acompanhar progresso.
- `callback_url`: callback do Worker do bot para finalização da ação.

### Dependências externas

O workflow faz checkout de:

- `Lucas25Pedrosa/Bot-Injector-Core` — código, configuração privada e binários de tweaks.
- `Lucas25Pedrosa/ipa-shared-config-core` — emojis e configuração compartilhada.

### Fluxo principal

```text
1. checkout deste repositório
2. checkout do Core privado
3. checkout da configuração compartilhada
4. instalação de Python/dependências
5. download do IPA mais recente do Telegram
6. validação ZIP/IPA
7. leitura do Info.plist
8. escolha da rota STANDARD ou privada/V5
9. seleção do addon
10. cópia/injeção de dylibs, bundles, frameworks e extensões
11. aplicação de patches específicos
12. pós-processamento privado quando aplicável
13. validações estruturais do IPA final
14. geração/validação dos metadados do pacote Feather
15. envio de Final.ipa ao Telegram
16. callback ao Worker
```

O workflow contém validações específicas por aplicativo para impedir que uma alteração estrutural produza um IPA aparentemente válido, mas incompatível.

## Rota STANDARD e rota privada/V5

A decisão de rota é feita usando Bundle ID e o Core privado.

- **STANDARD:** usa `config/addons.json` e a sequência normal de injeção.
- **Privada/V5:** usa `scripts/postprocess.py` / `postprocess_impl.py` para apps que precisam de patches estruturais específicos.
- Alguns apps começam em STANDARD e recebem V5 apenas sobre o `Final.ipa`, para preservar a ordem correta das transformações.

A lista efetiva e a lógica ficam no Core privado; este repositório apenas as executa.

## Metadados do Feather

Antes do envio final, o workflow usa `feather_package_transport.py` do Core para gerar dados como:

- Bundle ID;
- versão do app;
- nome do pacote/tweak;
- versão do pacote;
- `packageRevision`.

Esses metadados são associados externamente à mensagem do Telegram e **não alteram os bytes do IPA**.

Eles permitem que o Feather detecte atualização de tweak mesmo quando a versão do aplicativo não mudou.

## Progresso no Telegram

O workflow atualiza a mensagem temporária com etapas como:

- download;
- injeção;
- patch;
- upload;
- velocidade;
- percentual;
- tempo restante.

Os emojis vêm de `ipa-shared-config-core/injector_r2_emojis.json`, sempre com fallback Unicode.

## Workflows auxiliares

### `healthcheck.yml`

Executa um job pequeno e rápido para confirmar disponibilidade do GitHub Actions. É usado pelo ecossistema para distinguir indisponibilidade do runner de falhas reais do Injector.

### `build-messenger-name-fix.yml`

Workflow de desenvolvimento do Messenger. Compila/valida um componente específico sem alterar o pipeline de produção inteiro.

### `get-telegram-translation-channel-id.yml`

Ferramenta administrativa para localizar o ID correto do canal privado de tradução. O ID encontrado deve ser configurado como secret/variável adequada; não deve ser gravado com credenciais no código.

### `messenger-portuguese.yml`

Pipeline de construção dos componentes de tradução do Messenger. Entre outras validações, compila binário arm64, verifica símbolos/estruturas esperadas e publica artifact temporário para teste.

## Secrets esperados

Os nomes podem evoluir, mas o workflow principal atualmente depende de credenciais de categorias como:

- acesso ao `Bot-Injector-Core`;
- acesso ao `ipa-shared-config-core`;
- Telegram API ID/API hash/sessão;
- token/chat do bot;
- callbacks do Worker.

**Nunca adicionar valores reais ao README, YAML ou logs.** Somente os nomes das variáveis devem ser documentados.

## Repositórios relacionados

- **`Bot-Injector-Core`** — Core privado e binários.
- **`ipa-shared-config-core`** — configuração compartilhada.
- **`ipa-r2-automation`** — recebe posteriormente o IPA do canal de armazenamento e publica a IPA Library.
- **`ipa-r2-core`** — lógica privada de armazenamento/Feather.

## O que deve ser alterado aqui

Este repositório deve mudar quando for necessário:

- alterar a ordem das etapas do GitHub Actions;
- adicionar/remover validações no workflow;
- alterar dependências do runner;
- expor uma nova entrada `workflow_dispatch`;
- alterar a integração de callback/progresso.

A configuração de quais tweaks um app recebe deve, em regra, ser alterada em `Bot-Injector-Core/config/addons.json`, não diretamente aqui.

## Segurança operacional

- Não remover validações de ZIP, Bundle ID, Mach-O ou pós-processamento apenas para “fazer o workflow passar”.
- Não trocar binários de tweak no repositório público.
- Não expor secrets em `echo`, artifacts ou logs.
- Ao adicionar um novo app, primeiro cadastrar/configurar no Core privado e depois validar o workflow.
- Alterações no pipeline devem preservar a geração do `Final.ipa` e o contrato com o Telegram/automação seguinte.
