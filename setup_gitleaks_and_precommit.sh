#!/usr/bin/env bash
# ============================================================
# Instala gitleaks, varre TODO o historico do git (nao so os
# arquivos atuais) em busca de segredos vazados, e configura
# pre-commit para bloquear automaticamente no futuro.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash setup_gitleaks_and_precommit.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/4 - Instalando gitleaks ==="
if ! command -v gitleaks &>/dev/null; then
  GITLEAKS_VERSION="8.21.2"
  TMPDIR=$(mktemp -d)
  curl -sSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    -o "$TMPDIR/gitleaks.tar.gz"
  tar -xzf "$TMPDIR/gitleaks.tar.gz" -C "$TMPDIR"
  sudo mv "$TMPDIR/gitleaks" /usr/local/bin/gitleaks
  rm -rf "$TMPDIR"
else
  echo "gitleaks ja instalado: $(gitleaks version)"
fi

echo "=== 2/4 - Varrendo TODO o historico do git (nao so o estado atual) ==="
echo "Isso verifica cada commit ja feito, incluindo os antigos onde"
echo "geramos .env/senhas - importante porque um arquivo removido"
echo "depois ainda fica no historico do git."
echo
set +e
gitleaks detect --source . --verbose --report-format json --report-path /tmp/gitleaks-report.json
GITLEAKS_EXIT=$?
set -e

echo
if [ $GITLEAKS_EXIT -eq 0 ]; then
  echo "✅ Nenhum segredo encontrado em todo o historico. Repositorio limpo."
else
  echo "⚠️  gitleaks encontrou possiveis segredos - ver detalhes acima e em /tmp/gitleaks-report.json"
  echo "    NAO publique o repositorio no GitHub antes de resolver isso."
fi

echo "=== 3/4 - Instalando pre-commit ==="
uv add --dev pre-commit

cat > .pre-commit-config.yaml << 'PRECOMMITEOF'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.0
    hooks:
      - id: ruff
      - id: ruff-format

  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
        args: ["--maxkb=5000"]  # bloqueia commit acidental de arquivo grande
                                  # (ex: se algum dia esquecer o .gitignore
                                  # da reference_library de novo)
PRECOMMITEOF

echo "=== 4/4 - Ativando o hook no repositorio local ==="
uv run pre-commit install

echo
echo "============================================================"
echo "gitleaks + pre-commit configurados."
echo
echo "A partir de agora, TODO commit passa automaticamente por:"
echo "  - lint/format (ruff)"
echo "  - deteccao de segredos (gitleaks)"
echo "  - higiene basica de arquivo"
echo "  - bloqueio de arquivo grande (>5MB) sem voce precisar lembrar"
echo
echo "Teste rodando manualmente em todos os arquivos (sem precisar"
echo "fazer um commit de verdade):"
echo "  uv run pre-commit run --all-files"
echo "============================================================"
