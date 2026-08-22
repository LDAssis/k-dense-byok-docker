# K-Dense BYOK (Kady) em Docker

Orquestração em Docker Compose do [K-Dense BYOK](https://github.com/K-Dense-AI/k-dense-byok) — o assistente de pesquisa Kady — com **toda a configuração e todos os dados em volumes no host**.

O código do upstream **não** é versionado aqui: o `Dockerfile` clona o repositório fixado por `KADY_REF`. Este projeto contém apenas os artefatos de orquestração.

---

## Requisitos

- Docker Engine com o plugin **Docker Compose >= 2.24** (`docker compose version`) — a sintaxe longa de `env_file` usada aqui depende dessa versão.
- ~12 GB de disco para as imagens — `kady-server` 7,7 GB e `kady-web` 4,4 GB (ver [Imagem menor](#imagem-menor)) e rede no build (clone do upstream, npm, apt, PyPI).
- `make` e `curl` no host.

---

## Início rápido

```bash
make setup                      # cria .env, config/ e data/
$EDITOR config/kady.env         # opcional: OPENROUTER_API_KEY=...
make up                         # builda e sobe
```

Abra **http://localhost:3000**. O primeiro build leva bastante tempo (TeX Live + venv científico) e o primeiro boot baixa o catálogo de skills — acompanhe com `make logs`.

Não precisa colocar chave nenhuma no arquivo: dá para configurar tudo depois em **Settings → API keys** / **Model providers**, e o Kady grava de volta em `config/kady.env`.

---

## Arquitetura

| Serviço | Porta | Papel |
|---|---|---|
| `kady-server` | 8000 | Backend Fastify + agente Pi. Sandbox, arquivos, sessões, ledger de custo, LaTeX, previews científicos |
| `kady-web` | 3000 | Frontend Next.js |

**As duas portas são publicadas de propósito.** A UI do Kady é 100% client-side: quem chama a API (incluindo o SSE do chat e os uploads) é o browser do host, não o container do frontend.

## Volumes

```
config/
  kady.env      →  /app/.env  (symlink)     chaves de API e preferências
data/
  projects/     →  /app/projects            projetos, sandboxes, sessões, custos
  kady/         →  /home/kady/.kady         tokens OAuth + cache de skills
    pi-agent/auth.json
    skills-cache/
```

`config/kady.env` é gerado no `make setup` (ou pelo entrypoint, no primeiro boot) a partir do `.env.example` do upstream. Ele é montado como **diretório** `./config` e ligado por symlink em `/app/.env`, porque a UI de Settings reescreve esse arquivo — assim as chaves gravadas pela interface persistem no host e sobrevivem a rebuilds.

Os arquivos que o agente cria aparecem diretamente em `data/projects/<projeto>/sandbox/`, com o seu UID (`PUID`/`PGID`).

## Configuração

Há **dois** arquivos de ambiente, com papéis distintos:

| Arquivo | Lido por | Contém |
|---|---|---|
| `.env` (raiz) | docker compose | `KADY_REF`, portas, `PUID`/`PGID`, flags de build |
| `config/kady.env` | a aplicação Kady | `OPENROUTER_API_KEY`, `DEFAULT_MODEL_ID`, `NVIDIA_API_KEY`, `MODAL_TOKEN_*`, ... |

Variáveis do compose (ver `.env.example`):

| Variável | Default | Para quê |
|---|---|---|
| `KADY_REF` | `v0.9.9` | Tag/branch/commit do upstream |
| `PUID` / `PGID` | `1000` | Dono dos arquivos em `config/` e `data/` |
| `BIND_ADDR` | `127.0.0.1` | Onde as portas são publicadas |
| `KADY_UI_PORT` / `KADY_API_PORT` | `3000` / `8000` | Portas no host |
| `KADY_PUBLIC_API_URL` | `http://localhost:8000` | URL da API vista pelo browser (**build-time**) |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434` | Ollama no host |
| `INSTALL_TEXLIVE` | `1` | TeX Live (~2 GB) |
| `INSTALL_SCI_HELPERS` | `1` | rdkit/gemmi/anndata/... (~2 GB) |
| `WARM_UV_CACHE` | `1` | numpy/pandas/matplotlib/scipy pré-baixados (~0,5 GB) |
| `KADY_AUTO_UPDATE` | `0` | `1` = força `@latest` dos pacotes Pi a cada boot |

Alterações em `config/kady.env` exigem só `make restart`. Alterações em `KADY_PUBLIC_API_URL` exigem `make build-web` (o Next embute a URL no bundle).

## Segurança

O Kady **não tem autenticação**. Com o default `BIND_ADDR=127.0.0.1` o serviço só é acessível da própria máquina. Publicar em `0.0.0.0` entrega, a qualquer um na rede, suas chaves de API e execução de shell/Python arbitrária dentro do container. Se precisar de acesso remoto, ponha atrás de um proxy reverso com autenticação ou use um túnel SSH:

```bash
ssh -L 3000:localhost:3000 -L 8000:localhost:8000 usuario@maquina
```

Em compensação, o agente executa código dentro do container, e não direto no host — é mais isolado do que o modo nativo (`./start.sh`).

## Modelos locais (Ollama / LM Studio / vLLM)

Dentro do container, `localhost` é o próprio container. Use `host.docker.internal`, que já está mapeado para o host via `extra_hosts`.

**Ollama** — configure no `.env` da raiz, **não** em `config/kady.env`: o compose define `OLLAMA_BASE_URL` explicitamente (para não herdar o `localhost` do exemplo do upstream) e essa definição vence sobre o arquivo da aplicação.

```
# .env (raiz)
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

**Servidores OpenAI-compatíveis** (LM Studio, vLLM, llama.cpp) — o compose não mexe nessa variável, então ela vai em `config/kady.env`:

```
# config/kady.env
OPENAI_COMPATIBLE_BASE_URL=http://host.docker.internal:1234
```

> Regra geral: o que o compose declara em `environment:` (portas, paths de dados, `KADY_HOST`, `OLLAMA_BASE_URL`) sobrepõe o `config/kady.env`. Todo o resto — chaves de API, modelo default, limites de gasto — vem do `config/kady.env`.

## Rodando num servidor

Num servidor acessado de outra máquina, `make setup && make up` sobe os
serviços, mas o navegador **não** vai conseguir usar a UI sem um dos dois
ajustes abaixo. O motivo é que o endereço da API é embutido no bundle do Next
durante o build: por padrão `http://localhost:8000`, que no seu navegador
resolve para a *sua* máquina, não para o servidor.

### Opção A — túnel SSH (recomendado, e sem rebuild)

Mantém o default `BIND_ADDR=127.0.0.1`: o Kady fica inacessível pela rede e o
tráfego trafega cifrado. Como o túnel usa as mesmas portas locais, o
`localhost:8000` embutido no bundle continua correto.

```bash
# no servidor
make setup && make up

# na sua máquina
ssh -L 3000:localhost:3000 -L 8000:localhost:8000 usuario@servidor
```

Abra `http://localhost:3000`.

### Opção B — expor na rede (exige rebuild e proteção externa)

```bash
# .env no servidor
BIND_ADDR=0.0.0.0
KADY_PUBLIC_API_URL=http://IP-DO-SERVIDOR:8000
```

```bash
make build-web && make up    # o rebuild é obrigatório: a URL vai no bundle
```

> **O Kady não tem autenticação.** Nesta opção, qualquer um que alcance as
> portas 3000/8000 usa suas chaves de API e executa shell e Python arbitrários
> dentro do container. Só faça isso atrás de um firewall fechado, VPN, ou de um
> proxy reverso que exija autenticação — nunca direto na internet.

### Requisitos de máquina para o build

- **~12 GB de disco** para as imagens, mais o cache do BuildKit.
- **≥ 4 GB de RAM**: o `next build` é a etapa mais pesada e pode ser morto por
  OOM em VPS pequenas. Se acontecer, builde num servidor maior e envie a
  imagem com `docker save`/`docker load`, ou desligue os extras (ver
  [Imagem menor](#imagem-menor)).
- O build leva ~20 min e precisa de rede (GitHub, npm, apt, PyPI).

### O que não viaja no repositório

Chaves de API e credenciais ficam de fora do git por design. Num servidor novo
você recomeça com `config/kady.env` limpo e informa as chaves ali, ou pela UI
em **Settings → API keys**.

## Imagem menor

Os extras respondem por quase todo o tamanho do `kady-server` (7,7 GB medidos). Para reduzir bastante, no `.env`:

```
INSTALL_TEXLIVE=0        # perde compilação LaTeX e sync PDF↔fonte
INSTALL_SCI_HELPERS=0    # perde previews de formatos científicos
WARM_UV_CACHE=0          # a 1ª análise do agente baixa numpy/pandas/...
```

Depois: `make build && make up`.

## Atualizar o Kady

```bash
$EDITOR .env             # KADY_REF=v0.9.10
make update
```

`config/` e `data/` são preservados. Para atualizar só os pacotes do agente Pi sem rebuild, use `KADY_AUTO_UPDATE=1` e `make restart`.

## Comandos

```
make setup       cria .env, config/ e data/
make up          builda e sobe
make down        para (dados preservados)
make logs        logs dos dois serviços
make health      checa os endpoints de saúde
make shell       shell no backend, como usuário kady
make build-web   rebuilda só o frontend
make update      rebuilda no KADY_REF atual e sobe
make clean-data  APAGA ./data (irreversível)
```

## Problemas comuns

**`permission denied ... /var/run/docker.sock`.** Seu usuário não está no grupo `docker`. Ou entre no grupo (e reabra a sessão):

```bash
sudo usermod -aG docker "$USER"   # requer logout/login para valer
```

ou rode tudo com `sudo`, sobrescrevendo o comando do Makefile:

```bash
make up COMPOSE="sudo docker compose"
```

**A UI abre mas não carrega os projetos.** O browser não está alcançando a API. Confirme `curl http://localhost:8000/health` e que `KADY_PUBLIC_API_URL` bate com o endereço pelo qual você acessa a UI (após mudar: `make build-web`).

**Arquivos em `data/` como root.** `PUID`/`PGID` diferentes dos seus. Ajuste no `.env` e `make restart` — o entrypoint realinha o usuário.

**O primeiro boot demora muito.** É o `prep`: cria o projeto default, baixa o catálogo de skills e sincroniza o venv do sandbox. `make logs-server` mostra o progresso. Para pular: `KADY_SKIP_PREP=1`.

**OAuth (Claude Pro, ChatGPT, Copilot, xAI).** Os fluxos são por device code / link manual e funcionam no container; os tokens ficam em `data/kady/pi-agent/auth.json`. Provedores por chave (OpenRouter, NVIDIA) não têm essa etapa.

## Licença

Os artefatos de orquestração deste repositório acompanham a licença MIT do upstream. O K-Dense BYOK é software de terceiros — veja o [repositório original](https://github.com/K-Dense-AI/k-dense-byok).
