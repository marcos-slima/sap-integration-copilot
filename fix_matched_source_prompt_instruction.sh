#!/usr/bin/env bash
# ============================================================
# Fix real (baseado em evidencia, nao suposicao): a correcao
# anterior (Field(description=...)) nao teve efeito nenhum -
# outputs identicos, byte a byte, confirmando que a descricao do
# schema Pydantic NAO chega ao modelo como orientacao textual via
# with_structured_output no Ollama - so restringe tipo/formato.
#
# Correcao real: instrucao explicita de volta no TEXTO do prompt,
# nao so no schema.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_matched_source_prompt_instruction.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

python3 - << 'PYEOF'
from pathlib import Path

path = Path("app/agent/graph.py")
text = path.read_text(encoding="utf-8")

old = '''Regra importante: baseie sua resposta EXCLUSIVAMENTE no documento de
contexto acima e, se disponivel, nos dados reais do conector (que tem
prioridade sobre a descricao textual do usuario, pois vem diretamente
do sistema). Nao combine informacoes de outros documentos. Se o
documento acima nao corresponder ao sintoma descrito, diga isso e use
confidence baixa em vez de inventar uma causa raiz combinando temas
diferentes.

"confidence" deve ser um numero entre 0.0 e 1.0. Se houver dados reais
do conector confirmando o diagnostico, a confidence pode ser mais alta
(o dado do sistema e mais confiavel que so a descricao textual)."""'''

new = '''Regra importante: baseie sua resposta EXCLUSIVAMENTE no documento de
contexto acima e, se disponivel, nos dados reais do conector (que tem
prioridade sobre a descricao textual do usuario, pois vem diretamente
do sistema). Nao combine informacoes de outros documentos. Se o
documento acima nao corresponder ao sintoma descrito, diga isso e use
confidence baixa em vez de inventar uma causa raiz combinando temas
diferentes.

No campo matched_source, copie EXATAMENTE o nome do arquivo indicado
apos "fonte=" no cabecalho do documento mais relevante mostrado acima
(exemplo: se o cabecalho diz "fonte=cpi_http_401.md", o valor de
matched_source deve ser exatamente "cpi_http_401.md", sem alteracoes).
Se nenhum documento corresponder ao incidente, use null nesse campo.

"confidence" deve ser um numero entre 0.0 e 1.0. Se houver dados reais
do conector confirmando o diagnostico, a confidence pode ser mais alta
(o dado do sistema e mais confiavel que so a descricao textual)."""'''

if old not in text:
    print("AVISO: bloco final do prompt nao encontrado - verifique manualmente.")
else:
    text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
    print("Instrucao explicita de matched_source restaurada no prompt.")
PYEOF

uv run ruff check --fix app/agent/graph.py
uv run ruff format app/agent/graph.py

echo
echo "============================================================"
echo "Correcao aplicada. ANTES de rodar a suite completa (2min),"
echo "confirme rapido com um teste isolado e --debug:"
echo
echo "  uv run python -m app.agent.graph --interface rfc --id RFC-IDOC-51-DEMO \"IDoc travado\" --debug"
echo
echo "Confira no console: o prompt agora deve conter a linha"
echo "'No campo matched_source, copie EXATAMENTE...', e a resposta"
echo "final deve trazer matched_source preenchido, nao null."
echo
echo "So depois disso confirmado, rode a suite completa:"
echo "  uv run pytest -v"
echo "============================================================"
