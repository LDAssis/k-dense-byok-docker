#!/usr/bin/env bash
#
# Entrypoint do backend Kady.
#
# Roda como root apenas o tempo necessário para: alinhar o UID/GID do usuário
# `kady` com o do host, materializar o arquivo de configuração dentro do
# volume compartilhado e ajustar permissões. Depois dropa para `kady`.
set -euo pipefail

APP_DIR=/app
SERVER_DIR="$APP_DIR/server"
CONFIG_DIR="${KADY_CONFIG_DIR:-$APP_DIR/config}"
CONFIG_FILE="$CONFIG_DIR/kady.env"
KADY_HOME="${KADY_HOME_DIR:-/home/kady}"
PROJECTS_DIR="${KADY_PROJECTS_ROOT:-$APP_DIR/projects}"

log() { printf '[kady-entrypoint] %s\n' "$*"; }

# --- 1. alinhar UID/GID com o host ------------------------------------------
# Permite corrigir PUID/PGID sem rebuild da imagem.
current_uid="$(id -u kady)"
current_gid="$(id -g kady)"
want_uid="${PUID:-$current_uid}"
want_gid="${PGID:-$current_gid}"

# usermod não consegue renumerar root; PUID=0 quebraria o container em runtime
# da mesma forma que quebra o build.
if [ "$want_uid" = "0" ] || [ "$want_gid" = "0" ]; then
  log "ERRO: PUID/PGID não podem ser 0 (root). Ajuste no .env (ex.: 1000)."
  exit 1
fi

if [ "$want_gid" != "$current_gid" ]; then
  log "ajustando GID de kady: $current_gid -> $want_gid"
  groupmod -o -g "$want_gid" kady
  usermod -o -g "$want_gid" kady
fi
if [ "$want_uid" != "$current_uid" ]; then
  log "ajustando UID de kady: $current_uid -> $want_uid"
  usermod -o -u "$want_uid" kady
fi

# --- 2. diretórios persistentes ---------------------------------------------
mkdir -p \
  "$CONFIG_DIR" \
  "$PROJECTS_DIR" \
  "$KADY_HOME/.kady/pi-agent" \
  "$KADY_HOME/.kady/skills-cache"

# --- 3. bootstrap do arquivo de configuração --------------------------------
# O volume ./config é montado como DIRETÓRIO (nunca como arquivo): um bind
# mount de arquivo inexistente é criado pelo Docker como diretório e quebraria
# tudo. O kady.env nasce aqui, a partir do .env.example do upstream.
if [ ! -f "$CONFIG_FILE" ]; then
  if [ -f "$APP_DIR/.env.example" ]; then
    log "config/kady.env não existe — gerando a partir de .env.example"
    cp "$APP_DIR/.env.example" "$CONFIG_FILE"
  else
    log "config/kady.env não existe e não há .env.example — criando vazio"
    : > "$CONFIG_FILE"
  fi
fi

# O backend lê <REPO_ROOT>/.env e a UI (Settings → API keys) REESCREVE esse
# mesmo caminho com writeFileSync. Um symlink faz a escrita atravessar para o
# arquivo do host, de modo que chaves gravadas pela UI persistem em
# config/kady.env e sobrevivem a rebuilds.
ln -sfn "$CONFIG_FILE" "$APP_DIR/.env"

# --- 4. permissões ----------------------------------------------------------
chown -h kady:kady "$APP_DIR/.env" || true
chown kady:kady "$APP_DIR" "$CONFIG_DIR" "$CONFIG_FILE" || true
chown -R kady:kady "$PROJECTS_DIR" "$KADY_HOME/.kady" || true
# Só re-chowna a árvore da app quando o UID mudou em runtime (é caro).
if [ "$want_uid" != "$current_uid" ] || [ "$want_gid" != "$current_gid" ]; then
  log "re-aplicando ownership em $APP_DIR e /opt/uv (pode demorar)"
  chown -R kady:kady "$APP_DIR" /opt/uv || true
fi

export HOME="$KADY_HOME"
# npm run coloca node_modules/.bin no PATH; como executamos o tsx diretamente,
# fazemos isso à mão — os processos filhos `pi` (pi-subagents) e a CLI `skills`
# são resolvidos por PATH.
export PATH="$SERVER_DIR/node_modules/.bin:$KADY_HOME/.local/bin:$PATH"

cd "$SERVER_DIR"

# --- 5. atualização opcional dos pacotes Pi ---------------------------------
# Replica o comportamento do launcher upstream (que força @latest a cada
# start). Desligado por padrão: a imagem é a fonte da verdade.
if [ "${KADY_AUTO_UPDATE:-0}" = "1" ]; then
  log "KADY_AUTO_UPDATE=1 — atualizando pacotes Pi para @latest"
  gosu kady npm install --no-audit --no-fund --loglevel=error \
    @earendil-works/pi-agent-core@latest \
    @earendil-works/pi-ai@latest \
    @earendil-works/pi-coding-agent@latest \
    pi-subagents@latest \
    pi-web-access@latest \
    skills@latest \
    || log "atualização falhou — seguindo com as versões da imagem"
fi

# --- 6. prep: projeto default, catálogo de skills, venv do sandbox ----------
# Idempotente. Falha aqui não impede o serviço de subir (mesmo comportamento
# do start.mjs upstream).
if [ "${KADY_SKIP_PREP:-0}" = "1" ]; then
  log "KADY_SKIP_PREP=1 — pulando o prep"
else
  log "preparando projetos (projeto default, skills científicas, venv do sandbox)..."
  gosu kady npm run prep || log "prep falhou/parcial — continuando"
fi

# --- 7. serviço -------------------------------------------------------------
log "iniciando backend em ${KADY_HOST:-0.0.0.0}:${KADY_PORT:-8000}"
exec gosu kady "$SERVER_DIR/node_modules/.bin/tsx" src/index.ts
