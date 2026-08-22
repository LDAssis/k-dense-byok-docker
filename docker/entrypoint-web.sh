#!/usr/bin/env bash
#
# Entrypoint do frontend Kady (Next.js já buildado na imagem).
set -euo pipefail

cd /app/web
exec ./node_modules/.bin/next start -H "${HOSTNAME:-0.0.0.0}" -p "${PORT:-3000}"
