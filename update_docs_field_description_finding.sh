#!/usr/bin/env bash
# ============================================================
# Registra o achado real: Field(description=...) do Pydantic NAO
# influencia o conteudo gerado via with_structured_output no
# Ollama - so restringe tipo/formato. Correcao real precisou de
# instrucao explicita em TEXTO no prompt.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash update_docs_field_description_finding.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

python3 - << 'PYEOF'
from pathlib import Path

path = Path("README.md")
text = path.read_text(encoding="utf-8")

marker = "    migrado para o padrão `lifespan` do FastAPI"
addition = '''
- **Achado adicional durante a correção do item acima:** a primeira
  tentativa de restaurar a orientação sobre `matched_source` usou
  `Field(description=...)` no schema Pydantic, assumindo que o
  LangChain injetaria essa descrição como contexto textual pro LLM.
  **Isso não teve efeito nenhum** — confirmado porque as respostas do
  modelo saíram byte-a-byte idênticas antes e depois da mudança
  (esperado com `temperature=0`/`seed` fixo apenas se o prompt
  realmente enviado não mudou). Causa real: `with_structured_output`
  no Ollama usa o schema JSON para restringir **tipo/formato** da
  geração (decodificação restrita por gramática), não para injetar
  descrições como instrução legível pelo modelo. A correção que
  funcionou de fato foi devolver a instrução como **texto explícito
  no prompt**, confirmada visualmente via `--debug` antes de rodar a
  suíte completa de novo. Lição: ao adotar saída estruturada via
  schema, texto explícito no prompt continua necessário para lógica
  de preenchimento — o schema garante a forma, não o conteúdo.'''

if marker in text and "byte-a-byte idênticas" not in text:
    text = text.replace(marker, marker + addition, 1)
    path.write_text(text, encoding="utf-8")
    print("Achado registrado no README.")
elif "byte-a-byte idênticas" in text:
    print("Achado ja registrado, pulando.")
else:
    print("AVISO: marcador nao encontrado no README - verifique manualmente.")
PYEOF

echo
echo "============================================================"
echo "Revise e comite:"
echo "  uv run pre-commit run --all-files"
echo "  git add -A"
echo "  git status   # confirme: nada de data/reference_library, .env"
echo "  git commit -m 'fix: corrige matched_source e Python re-pinado para 3.12'"
echo "  git push"
echo "============================================================"
