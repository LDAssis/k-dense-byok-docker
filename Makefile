SHELL := /bin/bash

# Carrega as variáveis do compose (se .env já existir) para usar KADY_REF aqui.
-include .env
export

KADY_REF   ?= v0.9.9
KADY_REPO  ?= https://github.com/K-Dense-AI/k-dense-byok.git
COMPOSE    ?= docker compose
RAW_BASE   := https://raw.githubusercontent.com/K-Dense-AI/k-dense-byok

.DEFAULT_GOAL := help

.PHONY: help setup up down restart logs logs-server logs-web ps build build-web \
        update check-update diff-config shell shell-web health config clean-data

help: ## Lista os alvos disponíveis
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## Cria .env, os diretórios de volume e config/kady.env
	@if [ ! -f .env ]; then \
	  cp .env.example .env; \
	  sed -i "s/^PUID=.*/PUID=$$(id -u)/; s/^PGID=.*/PGID=$$(id -g)/" .env; \
	  echo "criado: .env  (PUID=$$(id -u) PGID=$$(id -g) detectados)"; \
	 else echo "já existe: .env"; fi
	@mkdir -p config data/projects data/kady
	@if [ ! -f config/kady.env ]; then \
	  echo "buscando .env.example do upstream ($(KADY_REF))..."; \
	  if curl -fsSL "$(RAW_BASE)/$(KADY_REF)/.env.example" -o config/kady.env; then \
	    echo "criado: config/kady.env"; \
	  else \
	    echo "download falhou — criando config/kady.env vazio (o entrypoint o preenche no 1º boot)"; \
	    : > config/kady.env; \
	  fi; \
	else echo "já existe: config/kady.env"; fi
	@echo
	@echo "Próximos passos:"
	@echo "  1. edite config/kady.env  (ex.: OPENROUTER_API_KEY=...)"
	@echo "     — ou deixe em branco e configure depois em Settings → API keys"
	@echo "  2. acesso remoto? veja 'Rodando num servidor' no README"
	@echo "  3. make up"

build: ## Builda as duas imagens
	$(COMPOSE) build

build-web: ## Rebuilda só o frontend (necessário após mudar KADY_PUBLIC_API_URL)
	$(COMPOSE) build kady-web

up: setup ## Sobe os serviços em background
	$(COMPOSE) up -d --build
	@echo
	@echo "UI:      http://localhost:$${KADY_UI_PORT:-3000}"
	@echo "API:     http://localhost:$${KADY_API_PORT:-8000}"
	@echo "Logs:    make logs"
	@echo "(o primeiro boot baixa o catálogo de skills; pode levar alguns minutos)"

down: ## Para e remove os containers (dados permanecem em ./data)
	$(COMPOSE) down

restart: ## Reinicia os serviços
	$(COMPOSE) restart

logs: ## Segue os logs dos dois serviços
	$(COMPOSE) logs -f

logs-server: ## Segue os logs do backend
	$(COMPOSE) logs -f kady-server

logs-web: ## Segue os logs do frontend
	$(COMPOSE) logs -f kady-web

ps: ## Estado dos serviços
	$(COMPOSE) ps

health: ## Checa os endpoints de saúde a partir do host
	@echo -n "backend: "; curl -fsS "http://localhost:$${KADY_API_PORT:-8000}/health" && echo
	@echo -n "frontend: "; curl -fsS -o /dev/null -w '%{http_code}\n' "http://localhost:$${KADY_UI_PORT:-3000}/"

check-update: ## Lista as tags do upstream e mostra o KADY_REF em uso
	@echo "em uso: KADY_REF=$(KADY_REF)"
	@echo "últimas tags publicadas:"
	@git ls-remote --tags --refs $(KADY_REPO) 2>/dev/null \
	  | sed 's|.*refs/tags/||' | sort -V | tail -5 | sed 's/^/  /'

diff-config: ## Compara seu config/kady.env com o .env.example do KADY_REF
	@tmp=$$(mktemp); \
	 if curl -fsSL "$(RAW_BASE)/$(KADY_REF)/.env.example" -o "$$tmp"; then \
	   added=$$(comm -13 \
	     <(grep -oE '^[#[:space:]]*[A-Z_][A-Z0-9_]*=' config/kady.env | tr -d '# \t' | sort -u) \
	     <(grep -oE '^[#[:space:]]*[A-Z_][A-Z0-9_]*=' "$$tmp"          | tr -d '# \t' | sort -u)); \
	   if [ -n "$$added" ]; then \
	     echo "variáveis novas em $(KADY_REF) que não estão no seu config/kady.env:"; \
	     echo "$$added" | sed 's/^/  /'; \
	   else echo "config/kady.env cobre todas as variáveis de $(KADY_REF)."; fi; \
	 else echo "não consegui baixar o .env.example de $(KADY_REF)"; fi; \
	 rm -f "$$tmp"

update: ## Rebuilda no ref atual de KADY_REF e sobe de novo
	KADY_CACHEBUST=$$(date +%s) $(COMPOSE) build --pull
	$(COMPOSE) up -d

shell: ## Shell no backend (usuário kady)
	$(COMPOSE) exec -u kady kady-server bash

shell-web: ## Shell no frontend
	$(COMPOSE) exec kady-web bash

config: ## Mostra o compose resolvido
	$(COMPOSE) config

clean-data: ## APAGA ./data (projetos, sessões, credenciais OAuth). Irreversível.
	@read -p "Apagar ./data (projetos, sessões, tokens OAuth)? [y/N] " ok; \
	 [ "$$ok" = "y" ] && rm -rf data && mkdir -p data/projects data/kady && echo "removido" || echo "cancelado"
