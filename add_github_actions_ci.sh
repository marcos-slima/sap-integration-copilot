#!/usr/bin/env bash
# ============================================================
# Cria o workflow de CI (GitHub Actions) e adiciona o badge de
# status ao README.
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_github_actions_ci.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/2 - Criando .github/workflows/tests.yml ==="
mkdir -p .github/workflows
cat > .github/workflows/tests.yml << 'WORKFLOWEOF'
name: tests

on:
  push:
    branches: [master, main]
  pull_request:
    branches: [master, main]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: astral-sh/setup-uv@v3
        with:
          enable-cache: true

      - name: Instalar dependencias
        run: uv sync

      - name: Lint (ruff)
        run: uv run ruff check .

      - name: Rodar testes unitarios
        # So os testes SEM @pytest.mark.integration - os de integracao
        # precisam de Qdrant/Ollama locais, que nao existem no runner
        # do GitHub. Isso testa conectores, contratos e regras de
        # negocio puras, sem depender de infraestrutura externa.
        run: uv run pytest tests/test_connectors.py -v
WORKFLOWEOF

echo "=== 2/2 - Adicionando badge de status ao README ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("README.md")
text = path.read_text(encoding="utf-8")

badge = "![tests](https://github.com/marcos-slima/sap-integration-copilot/actions/workflows/tests.yml/badge.svg)\n\n"

if "actions/workflows/tests.yml/badge.svg" not in text:
    lines = text.split("\n", 1)
    # insere o badge logo apos o titulo (primeira linha, ex: "# SAP Integration Copilot")
    if lines[0].startswith("#"):
        text = lines[0] + "\n\n" + badge + (lines[1] if len(lines) > 1 else "")
    else:
        text = badge + text
    path.write_text(text, encoding="utf-8")
    print("Badge adicionado ao README.md")
else:
    print("Badge ja existe, pulando.")
PYEOF

echo
echo "============================================================"
echo "Workflow de CI criado. Commit e push para ativar:"
echo
echo "  git add .github/ README.md"
echo "  git commit -m 'ci: adiciona GitHub Actions (lint + testes unitarios)'"
echo "  git push"
echo
echo "Depois do push, acompanhe em:"
echo "  https://github.com/marcos-slima/sap-integration-copilot/actions"
echo
echo "O badge no README so fica verde depois da primeira execucao"
echo "bem-sucedida do workflow - normal levar 1-2 minutos apos o push."
echo "============================================================"
