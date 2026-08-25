#!/usr/bin/env bash
# ============================================================
# Adiciona link para docs/PROCESSO_DESENVOLVIMENTO.md logo no
# topo do README.md (apos o badge de CI, se existir).
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash link_process_doc_in_readme.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

if [ ! -f docs/PROCESSO_DESENVOLVIMENTO.md ]; then
  echo "ERRO: docs/PROCESSO_DESENVOLVIMENTO.md nao encontrado."
  echo "Mova o arquivo para docs/ antes de rodar este script."
  exit 1
fi

python3 - << 'PYEOF'
from pathlib import Path

path = Path("README.md")
lines = path.read_text(encoding="utf-8").split("\n")

link_line = "> 📋 Veja o [processo de desenvolvimento](docs/PROCESSO_DESENVOLVIMENTO.md) seguido neste projeto, fase por fase."

if "PROCESSO_DESENVOLVIMENTO.md" in "\n".join(lines):
    print("Link ja existe no README, pulando.")
else:
    insert_at = None
    for i, line in enumerate(lines):
        if "badge.svg" in line:
            insert_at = i + 1
            break
    if insert_at is None:
        # fallback: logo apos a primeira linha (titulo)
        insert_at = 1

    lines.insert(insert_at, "")
    lines.insert(insert_at + 1, link_line)
    Path("README.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"Link inserido na linha {insert_at + 2}.")
PYEOF

echo
echo "============================================================"
echo "Revise: head -10 README.md"
echo
echo "Commit:"
echo "  git add README.md"
echo "  git commit -m 'docs: linka processo de desenvolvimento no topo do README'"
echo "  git push"
echo "============================================================"
