# data/

Todos os dados do usuário, montados nos containers. **Nada aqui é versionado.**

```
data/
├── projects/     →  /app/projects        projetos, sandboxes, sessões, ledger de custo
└── kady/         →  /home/kady/.kady
    ├── pi-agent/
    │   └── auth.json    ← TOKENS OAuth (Claude, ChatGPT, Copilot, xAI)
    └── skills-cache/    ← catálogo de skills baixado
```

Os arquivos pertencem ao seu usuário (`PUID`/`PGID` no `.env`), então dá para
abrir, editar e fazer backup direto do host — o que o agente escreve no sandbox
aparece em `data/projects/<projeto>/sandbox/`.

> `data/kady/pi-agent/auth.json` guarda credenciais de sessão dos provedores.
> Trate este diretório como você trataria `~/.ssh`.

Para zerar tudo: `make clean-data` (irreversível).
