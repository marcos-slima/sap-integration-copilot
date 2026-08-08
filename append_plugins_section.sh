#!/usr/bin/env bash
# ============================================================
# Adiciona secao "Plugins por Ferramenta" (IDs concretos de
# instalacao) ao docs/ferramentas-sustentacao-ecossistema.md
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash append_plugins_section.sh
# ============================================================
set -e

TARGET="docs/ferramentas-sustentacao-ecossistema.md"

if [ ! -f "$TARGET" ]; then
  echo "ERRO: $TARGET nao encontrado. Coloque o arquivo em docs/ primeiro."
  exit 1
fi

cat >> "$TARGET" << 'PLUGINSEOF'

## 14. Plugins por Ferramenta (IDs concretos)

As seções anteriores citaram "extensões"/"plugins" de forma genérica.
Aqui estão os identificadores exatos, prontos para instalar.

### VS Code (via `code --install-extension <id>` ou pela aba Extensions)

| Extensão | ID | Propósito |
|---|---|---|
| Python | `ms-python.python` | Suporte base a Python |
| Pylance | `ms-python.vscode-pylance` | Autocomplete/checagem de tipo inline |
| Ruff | `charliermarsh.ruff` | Lint/format em tempo real, usa o mesmo Ruff do projeto |
| Mypy Type Checker | `ms-python.mypy-type-checker` | Checagem de tipos inline (complementa o Pylance) |
| Docker | `ms-azuretools.vscode-docker` | Gerenciar containers/compose direto no editor |
| GitLens | `eamodio.gitlens` | Blame, histórico, navegação de branches |
| Even Better TOML | `tamasfe.even-better-toml` | Syntax/validação do `pyproject.toml` |
| YAML | `redhat.vscode-yaml` | Syntax/validação do `docker-compose.yml`, `promptfooconfig.yaml`, GitHub Actions |
| Markdown Mermaid | `bierner.markdown-mermaid` | Preview dos diagramas Mermaid do README direto no editor |
| REST Client | `humao.rest-client` | Testar o `/diagnose` com arquivos `.http` versionáveis no repo — alternativa in-editor ao Bruno/HTTPie |

Instalação em lote:
```bash
code --install-extension ms-python.python \
     --install-extension ms-python.vscode-pylance \
     --install-extension charliermarsh.ruff \
     --install-extension ms-python.mypy-type-checker \
     --install-extension ms-azuretools.vscode-docker \
     --install-extension eamodio.gitlens \
     --install-extension tamasfe.even-better-toml \
     --install-extension redhat.vscode-yaml \
     --install-extension bierner.markdown-mermaid \
     --install-extension humao.rest-client
```

### pre-commit (hooks — arquivo `.pre-commit-config.yaml` na raiz do repo)

| Hook | Repo | Propósito |
|---|---|---|
| ruff | `astral-sh/ruff-pre-commit` | Lint + format automático antes do commit |
| gitleaks | `gitleaks/gitleaks` | Bloqueia commit se detectar credencial/segredo |
| trailing-whitespace, end-of-file-fixer, check-yaml | `pre-commit/pre-commit-hooks` | Higiene básica de arquivo (o mesmo tipo de problema de whitespace que já nos mordeu no prompt do LangGraph) |

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.0
    hooks:
      - id: ruff
      - id: ruff-format
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.0
    hooks:
      - id: gitleaks
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
```

Ativar:
```bash
uv add --dev pre-commit
uv run pre-commit install
```

### pytest (plugins via `uv add --dev`)

| Plugin | Propósito |
|---|---|
| `pytest-cov` | Relatório de cobertura de teste integrado ao pytest (equivalente ao `coverage.py` standalone da seção 9, mas já plugado no `pytest -v --cov`) |
| `pytest-asyncio` | Necessário quando os endpoints do FastAPI (`app/main.py`) ganharem testes de verdade, já que FastAPI é assíncrono |
| `pytest-mock` | Mocka chamadas ao Ollama/Qdrant em testes unitários rápidos, sem depender da stack no ar (complementa o `conftest.py` que já pula testes de integração) |

```bash
uv add --dev pytest-cov pytest-asyncio pytest-mock
```

### tmux (via Tmux Plugin Manager — TPM)

| Plugin | Propósito |
|---|---|
| `tmux-resurrect` | Salva os painéis abertos (logs, uvicorn, etc.) e restaura depois de reiniciar a máquina |
| `tmux-continuum` | Auto-salva as sessões do `tmux-resurrect` periodicamente, sem ação manual |

### GitHub Actions (actions do marketplace, para o workflow de CI)

| Action | Propósito |
|---|---|
| `actions/checkout@v4` | Clona o repo no runner |
| `astral-sh/setup-uv@v3` | Instala o `uv` no runner do CI — mesma ferramenta usada localmente, sem duplicar lógica de dependência |
| `actions/cache@v4` | Cacheia o `uv.lock`/venv entre execuções, acelera o CI |

```yaml
# .github/workflows/tests.yml
name: tests
on: [push, pull_request]
jobs:
  pytest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v3
      - run: uv sync
      - run: uv run pytest tests/test_connectors.py -v
        # so os testes unitarios rodam no CI - os de integracao
        # (marcados @pytest.mark.integration) precisam da stack
        # local (Qdrant/Ollama) que nao existe no runner do GitHub
```
PLUGINSEOF

echo "Secao 'Plugins por Ferramenta' adicionada a $TARGET"
