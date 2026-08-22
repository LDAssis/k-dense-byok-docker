# config/

Este diretório é montado em `/app/config` no container do backend.

## `kady.env` (gerado, **nunca versionado**)

Guarda a configuração da aplicação Kady: `OPENROUTER_API_KEY`,
`NVIDIA_API_KEY`, `DEFAULT_MODEL_ID`, `MODAL_TOKEN_*`, chaves de busca, etc.

Não há um `kady.env.example` aqui de propósito — o modelo canônico é o
`.env.example` do próprio K-Dense BYOK, na versão fixada em `KADY_REF`.
Manter uma cópia neste repositório criaria uma segunda fonte de verdade que
envelheceria a cada atualização.

O arquivo nasce por dois caminhos independentes:

1. `make setup` baixa o `.env.example` da tag em uso e o salva como `kady.env`;
2. se ele ainda não existir no primeiro boot, o entrypoint do container o cria
   a partir do `.env.example` embutido na imagem.

Depois de criado, ele é **gravável pela UI**: o backend reescreve
`/app/.env` (symlink para este arquivo) quando você salva uma chave em
**Settings → API keys**, então o valor persiste aqui no host.

## Comandos úteis

```bash
make diff-config                     # variáveis novas na sua versão que faltam aqui
make diff-config KADY_REF=v0.9.10    # o mesmo, contra outra versão
```

> `kady.env` contém segredos e está no `.gitignore`. Não force o commit dele.
