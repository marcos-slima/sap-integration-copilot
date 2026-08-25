#!/usr/bin/env bash
# ============================================================
# Corrige regressao: DiagnosisModel sem Field(description=...)
# fazia o LLM nao saber o que preencher em matched_source (ficava
# sempre None, mesmo com o raciocinio correto em confidence e
# probable_root_cause - confirmado pelos 8 testes que falharam
# so nesse campo especifico).
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_structured_output_field_descriptions.sh
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

old = '''class DiagnosisModel(BaseModel):
    """Schema estruturado da resposta do LLM - usado via
    with_structured_output, valida o range de confidence na origem."""

    matched_source: str | None = None
    probable_root_cause: str
    confidence: float = Field(ge=0.0, le=1.0)
    next_steps: list[str] = Field(default_factory=list)'''

new = '''class DiagnosisModel(BaseModel):
    """Schema estruturado da resposta do LLM - usado via
    with_structured_output, valida o range de confidence na origem.

    IMPORTANTE: as descricoes (description=) nos campos abaixo NAO sao
    documentacao decorativa - o LangChain injeta esse texto no schema
    enviado ao LLM (via tool-calling), e e a UNICA orientacao semantica
    que o modelo recebe sobre o que cada campo significa. Removê-las
    (ou esquecer de adiciona-las) faz o LLM parar de saber o que
    preencher, mesmo continuando a raciocinar certo sobre o resto -
    foi exatamente isso que quebrou matched_source numa rodada anterior."""

    matched_source: str | None = Field(
        default=None,
        description=(
            "Nome EXATO do arquivo do documento de contexto usado como base "
            "para o diagnostico (ex: 'cpi_http_401.md'), copiado literalmente "
            "da linha 'fonte=...' do documento mais relevante fornecido. "
            "Use null se nenhum documento do contexto realmente corresponder "
            "ao incidente reportado."
        ),
    )
    probable_root_cause: str = Field(
        description=(
            "Causa raiz provavel do incidente, em uma ou duas frases, baseada "
            "EXCLUSIVAMENTE no documento de contexto fornecido e/ou nos dados "
            "reais do conector, quando disponiveis."
        )
    )
    confidence: float = Field(
        ge=0.0,
        le=1.0,
        description=(
            "Numero entre 0.0 e 1.0 indicando o quanto o contexto disponivel "
            "sustenta essa causa raiz. Dados reais do conector aumentam a "
            "confianca; ausencia de correspondencia clara deve resultar em "
            "confianca baixa (abaixo de 0.4)."
        ),
    )
    next_steps: list[str] = Field(
        default_factory=list,
        description="Lista de proximos passos praticos e concretos para investigar ou resolver o incidente.",
    )'''

if old not in text:
    print("AVISO: bloco DiagnosisModel esperado nao encontrado - verifique manualmente.")
else:
    text = text.replace(old, new)
    path.write_text(text, encoding="utf-8")
    print("DiagnosisModel corrigido com Field(description=...) em todos os campos.")
PYEOF

uv run ruff check --fix app/agent/graph.py
uv run ruff format app/agent/graph.py

echo
echo "============================================================"
echo "Correcao aplicada. Rode a suite completa de novo:"
echo "  uv run pytest -v"
echo
echo "Os 8 testes que falharam so por causa de matched_source=None"
echo "devem voltar a passar - confidence e probable_root_cause ja"
echo "estavam corretos, entao isso confirma que era so o campo"
echo "matched_source mesmo, nao um problema mais amplo."
echo "============================================================"
