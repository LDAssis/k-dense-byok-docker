# syntax=docker/dockerfile:1.7
#
# K-Dense BYOK (Kady) — imagens de container.
#
# Alvos:
#   base   → runtime comum (Node 22, git, bash, curl, uv, usuário `kady`)
#   source → clone pinado do upstream
#   web    → frontend Next.js já buildado          (enxuto, ~1 GB)
#   server → backend Fastify + toolchain científico (pesado, ~6-7 GB)
#
# O upstream NÃO é versionado neste repositório: ele é clonado no build,
# fixado por KADY_REF, para que este projeto contenha só a orquestração.

ARG NODE_IMAGE=node:22-bookworm-slim

# ---------------------------------------------------------------------------
# base
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base

ARG PUID=1000
ARG PGID=1000
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git gosu tini \
 && rm -rf /var/lib/apt/lists/*

# uv é obrigatório: todo Python que o agente roda no sandbox passa por
# `uv run` / `uv add` (ver server/src/sandbox-seed.ts no upstream).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# A imagem node:22 já traz um usuário `node` no UID 1000. Renomeamos (ou
# criamos) para `kady` no UID/GID pedido, de modo que os arquivos escritos
# nos bind mounts pertençam ao usuário do host, e não a root.
RUN set -eux; \
    if [ "${PUID}" = "0" ] || [ "${PGID}" = "0" ]; then \
      echo "ERRO: PUID/PGID não podem ser 0 (root)." >&2; \
      echo "  O container roda o agente como usuário sem privilégio; renomear o" >&2; \
      echo "  usuário root é impossível (usermod falha com 'currently used by" >&2; \
      echo "  process 1')." >&2; \
      echo "  Ajuste PUID/PGID no .env para um usuário comum, ex.: PUID=1000 PGID=1000." >&2; \
      echo "  Isso costuma acontecer ao rodar 'make setup' com sudo/como root." >&2; \
      exit 1; \
    fi; \
    if getent group "${PGID}" >/dev/null; then \
      groupmod -n kady "$(getent group "${PGID}" | cut -d: -f1)"; \
    else \
      groupadd -g "${PGID}" kady; \
    fi; \
    if getent passwd "${PUID}" >/dev/null; then \
      usermod -l kady -d /home/kady -m -g kady "$(getent passwd "${PUID}" | cut -d: -f1)"; \
    else \
      useradd -u "${PUID}" -g kady -m -d /home/kady -s /bin/bash kady; \
    fi; \
    mkdir -p /home/kady; \
    chown -R kady:kady /home/kady

# ---------------------------------------------------------------------------
# source — clone do upstream, pinado
# ---------------------------------------------------------------------------
FROM base AS source

ARG KADY_REPO=https://github.com/K-Dense-AI/k-dense-byok.git
ARG KADY_REF=v0.9.9
# Altere/passe um valor novo para forçar re-clone ignorando o cache de layer.
ARG KADY_CACHEBUST=0

RUN set -eux; \
    echo "cachebust=${KADY_CACHEBUST}"; \
    if ! git clone --depth 1 --branch "${KADY_REF}" "${KADY_REPO}" /src 2>/dev/null; then \
      git clone "${KADY_REPO}" /src; \
      git -C /src checkout --detach "${KADY_REF}"; \
    fi; \
    rm -rf /src/.git

# ---------------------------------------------------------------------------
# web — frontend Next.js
# ---------------------------------------------------------------------------
FROM base AS web

WORKDIR /app
# --chown no COPY já grava o dono certo: evita um `chown -R` posterior, que
# faria copy-up de todo o node_modules para um layer novo (medido em ~15 min).
COPY --from=source --chown=kady:kady /src/web /app/web
# web/next.config.ts lê a versão do app em ../server/package.json durante o
# build; sem esse arquivo o banner de "update available" fica sempre ligado.
COPY --from=source --chown=kady:kady /src/server/package.json /app/server/package.json

# O app é 100% client-side: quem chama a API é o BROWSER DO HOST, então esta
# URL precisa ser alcançável de fora do container. É inlined pelo Next no
# build — mudá-la exige `docker compose build kady-web`.
ARG NEXT_PUBLIC_ADK_API_URL=http://localhost:8000
ENV NEXT_PUBLIC_ADK_API_URL=${NEXT_PUBLIC_ADK_API_URL} \
    NEXT_TELEMETRY_DISABLED=1

ENV HOME=/home/kady
WORKDIR /app/web
# Instala e builda como `kady`: tudo que nasce daqui já tem o dono correto.
USER kady
# NODE_ENV fica em "development" aqui de propósito: tailwind/typescript/eslint
# são devDependencies e são necessários para o `next build`.
RUN npm ci --no-audit --no-fund --loglevel=error \
 || npm install --no-audit --no-fund --loglevel=error
# next/font/google em web/src/app/layout.tsx baixa e auto-hospeda as fontes:
# este passo precisa de rede.
RUN npx --no-install next build
# eslint/typescript/vitest/tailwind/shadcn só servem para buildar; `next start`
# precisa apenas das dependencies. Corta vários GB da imagem.
RUN npm prune --omit=dev --no-audit --no-fund --loglevel=error

USER root
COPY entrypoint-web.sh /usr/local/bin/entrypoint-web.sh
RUN chmod +x /usr/local/bin/entrypoint-web.sh

USER kady
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0
EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-web.sh"]

# ---------------------------------------------------------------------------
# server — backend + toolchain científico
# ---------------------------------------------------------------------------
FROM base AS server

ARG INSTALL_TEXLIVE=1
ARG INSTALL_SCI_HELPERS=1
ARG WARM_UV_CACHE=1
ENV DEBIAN_FRONTEND=noninteractive

# python3 do sistema (previews básicos), build-essential como rede de segurança
# para pacotes sem wheel manylinux.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-venv build-essential pkg-config \
 && rm -rf /var/lib/apt/lists/*

# TeX Live: latexmk/pdflatex/synctex habilitam a compilação LaTeX e o
# sync fonte<->PDF (server/src/latex/*). Custa ~2 GB.
RUN set -eux; \
    if [ "${INSTALL_TEXLIVE}" = "1" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        latexmk texlive-binaries texlive-latex-recommended \
        texlive-latex-extra texlive-fonts-recommended texlive-science; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# Caches do uv fora do $HOME para que sobrevivam ao bind mount de /home/kady.
ENV UV_CACHE_DIR=/opt/uv/cache \
    UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_LINK_MODE=copy

WORKDIR /app
COPY --from=source --chown=kady:kady /src /app

# Diretórios vazios: este chown é instantâneo, ao contrário de um `chown -R`
# sobre a árvore instalada. /opt/uv precisa existir mesmo quando os extras
# estão desligados, senão o uv não tem onde escrever.
RUN mkdir -p /opt/uv/cache /opt/uv/python /app/config /app/projects \
 && chown -R kady:kady /opt/uv /app/config /app/projects

ENV HOME=/home/kady
WORKDIR /app/server
USER kady
RUN npm ci --no-audit --no-fund --loglevel=error \
 || npm install --no-audit --no-fund --loglevel=error

# Venv dos helpers científicos (rdkit, gemmi, anndata, pydicom, nibabel,
# tifffile, ...) — habilita os previews de 60+ formatos sem espera no 1º boot.
RUN set -eux; \
    if [ "${INSTALL_SCI_HELPERS}" = "1" ]; then \
      cd /app/server/src/helpers && uv sync; \
    fi

# Pré-aquece o cache do uv com as dependências que sandbox-seed.ts semeia em
# todo projeto novo, para a primeira análise do agente não baixar tudo.
RUN set -eux; \
    if [ "${WARM_UV_CACHE}" = "1" ]; then \
      mkdir -p /tmp/warm && cd /tmp/warm; \
      printf '[project]\nname = "warm"\nversion = "0.1.0"\nrequires-python = ">=3.11"\ndependencies = ["numpy", "pandas", "matplotlib", "scipy"]\n' > pyproject.toml; \
      uv sync; \
      cd / && rm -rf /tmp/warm; \
    fi

# Volta para root: o entrypoint precisa dele para alinhar UID e ajustar os
# bind mounts antes de dropar para `kady` via gosu.
USER root
COPY entrypoint-server.sh /usr/local/bin/entrypoint-server.sh
RUN chmod +x /usr/local/bin/entrypoint-server.sh

ENV NODE_ENV=production \
    KADY_HOST=0.0.0.0 \
    KADY_PORT=8000 \
    HOME=/home/kady
WORKDIR /app/server
EXPOSE 8000
# Roda como root para ajustar UID/permissões dos bind mounts; o entrypoint
# dropa para `kady` via gosu antes de subir o serviço.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-server.sh"]
