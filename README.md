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

Toda configuração de modelo local vive em **`config/kady.env`**, junto com o
resto da configuração da aplicação. O `.env` da raiz cuida apenas de build e
publicação.

Dentro do container, `localhost` é o próprio container — use
`host.docker.internal`, que já está mapeado para o host via `extra_hosts`:

```bash
# config/kady.env
OLLAMA_BASE_URL=http://host.docker.internal:11434
OPENAI_COMPATIBLE_BASE_URL=http://host.docker.internal:1234
```

`make restart` e pronto. Os modelos aparecem no seletor de cada aba como
`ollama/<nome>` e `openai-compatible/<id>`. Para tornar um deles o padrão:

```bash
# config/kady.env
DEFAULT_MODEL_PROVIDER=ollama
DEFAULT_MODEL_ID=qwen3:8b
```

Ao **gerar** o `config/kady.env`, o entrypoint troca o `localhost` que vem no
exemplo do upstream por `host.docker.internal` — aquele valor nunca
funcionaria dentro de um container. Um arquivo que já existe pertence a você e
só recebe um aviso no log, sem ser editado.

Dois cuidados:

- **vLLM** usa a porta **8000** por padrão, a mesma do backend do Kady. Mude um
  dos dois.
- Modelos locais são contabilizados como **custo zero** e não consomem o limite
  de gasto do projeto. Por isso, não aponte `OPENAI_COMPATIBLE_BASE_URL` para um
  gateway pago: o gasto ficaria sem rastreio e sem teto.

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

### Opção B — expor na rede local

Funciona **apenas se o servidor estiver numa faixa de IP privada**
(`192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`). Veja a limitação de CORS abaixo.

As duas variáveis vão no **`.env` da raiz** (o arquivo do docker compose), não
em `config/kady.env`:

```bash
# .env
BIND_ADDR=0.0.0.0
KADY_PUBLIC_API_URL=http://192.168.68.125:8000   # IP do servidor, porta 8000
```

```bash
make build-web    # OBRIGATÓRIO: a URL é embutida no bundle do Next
make up
```

Acesse `http://192.168.68.125:3000`.

> **O Kady não tem autenticação.** Qualquer um que alcance as portas 3000/8000
> usa suas chaves de API e executa shell e Python arbitrários dentro do
> container. Só faça isso numa rede em que você confia.

#### Limitação: o CORS do upstream bloqueia IP público e domínio

`server/src/cors.ts` só libera `localhost`, `127.0.0.1`, `[::1]` e as faixas
privadas RFC1918. Comportamento medido contra o backend em execução:

| Origem do navegador | Resultado |
|---|---|
| `http://192.168.68.125:3000` | permitido |
| `http://10.0.0.5:3000` | permitido |
| `http://172.20.0.4:3000` | permitido |
| `http://203.0.113.5:3000` (IP público) | **bloqueado** |
| `http://kady.exemplo.com:3000` (domínio) | **bloqueado** |

Ou seja: **IP público ou nome de domínio não funcionam** nesta opção — a
página abre e toda chamada de API falha no navegador. Nesses casos use o
túnel SSH (Opção A), ou um proxy reverso que sirva UI e API **na mesma
origem** (aí não há CORS, e `KADY_PUBLIC_API_URL` aponta para essa origem).

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

**Build falha com `usermod: user root is currently used by process 1` (exit 8).**
`PUID`/`PGID` estão em `0` no `.env`, o que acontece ao rodar `make setup` com
sudo ou como root. O container não pode rodar como root. Corrija no `.env`:

```bash
sed -i "s/^PUID=.*/PUID=1000/; s/^PGID=.*/PGID=1000/" .env   # ou o id do seu usuário
make up
```

**Arquivos em `data/` como root.** `PUID`/`PGID` diferentes dos seus. Ajuste no `.env` e `make restart` — o entrypoint realinha o usuário.

**O primeiro boot demora muito.** É o `prep`: cria o projeto default, baixa o catálogo de skills e sincroniza o venv do sandbox. `make logs-server` mostra o progresso. Para pular: `KADY_SKIP_PREP=1`.

**OAuth (Claude Pro, ChatGPT, Copilot, xAI).** Os fluxos são por device code / link manual e funcionam no container; os tokens ficam em `data/kady/pi-agent/auth.json`. Provedores por chave (OpenRouter, NVIDIA) não têm essa etapa.

## Licença

Os artefatos de orquestração deste repositório acompanham a licença MIT do upstream. O K-Dense BYOK é software de terceiros — veja o [repositório original](https://github.com/K-Dense-AI/k-dense-byok).
