#!/usr/bin/env bash
# ============================================================
# Cria o grafo LangGraph (retrieve -> diagnose -> report) e liga
# no endpoint /diagnose do FastAPI.
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_langgraph_agent.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 0/3 - Atualizando app/models.py com matched_source ==="
cat > app/models.py << 'MODELSEOF'
"""Modelos Pydantic do SAP Integration Copilot."""
from pydantic import BaseModel


class IncidentRequest(BaseModel):
    description: str
    logs: str | None = None
    payload: str | None = None


class DiagnosisResponse(BaseModel):
    probable_root_cause: str
    confidence: float
    next_steps: list[str]
    report_markdown: str
    matched_source: str | None = None
MODELSEOF

echo "=== 1/3 - Criando app/agent/graph.py ==="
cat > app/agent/graph.py << 'GRAPHEOF'
"""Grafo LangGraph do SAP Integration Copilot.

Fluxo linear (v1):

    retrieve -> diagnose -> report

  retrieve  : consulta a base de incidentes (Qdrant) via app.rag.retriever
  diagnose  : chama o LLM local (Ollama) com o contexto recuperado e
              pede causa raiz, confianca e proximos passos em JSON
  report    : formata a resposta final em Markdown

Uso:
    from app.agent.graph import run_diagnosis
    from app.models import IncidentRequest

    result = run_diagnosis(IncidentRequest(description="..."))
"""
import json
from typing import TypedDict

from langchain_ollama import ChatOllama
from langgraph.graph import END, StateGraph

from app.models import DiagnosisResponse, IncidentRequest
from app.rag.retriever import retrieve

LLM_MODEL = "qwen3:30b-a3b"


class CopilotState(TypedDict, total=False):
    description: str
    logs: str | None
    payload: str | None
    retrieved_context: list[dict]
    diagnosis: dict
    report_markdown: str


def retrieve_node(state: CopilotState) -> CopilotState:
    hits = retrieve(state["description"], target="incidents", top_k=3)
    return {"retrieved_context": hits}


def _build_diagnosis_prompt(state: CopilotState) -> str:
    hits = state.get("retrieved_context", [])
    top_hit = hits[0] if hits else None
    other_sources = [h["source"] for h in hits[1:]]

    if top_hit:
        context_block = (
            f"--- Documento mais relevante (fonte={top_hit['source']}, "
            f"score={top_hit['score']:.3f}) ---\n{top_hit['text']}"
        )
    else:
        context_block = "(nenhum contexto relevante encontrado)"

    others_note = (
        f"\nOutras fontes candidatas, menos relevantes, cujo conteudo NAO foi "
        f"incluido aqui (ignore-as a menos que o documento acima claramente nao "
        f"corresponda ao incidente): {', '.join(other_sources)}\n"
        if other_sources else ""
    )

    extras = ""
    if state.get("logs"):
        extras += f"\nLogs:\n{state['logs']}\n"
    if state.get("payload"):
        extras += f"\nPayload:\n{state['payload']}\n"

    return f"""Voce e um especialista em integracao SAP (OData, IDoc, RFC, CPI).

Incidente reportado:
{state['description']}
{extras}

Contexto recuperado da base de conhecimento de incidentes:
{context_block}
{others_note}
Regra importante: baseie sua resposta EXCLUSIVAMENTE no documento acima.
Nao combine informacoes de outros documentos. Se o documento acima nao
corresponder ao sintoma descrito, diga isso e use confidence baixa em
vez de inventar uma causa raiz combinando temas diferentes.

Responda APENAS com um JSON valido no seguinte formato, sem texto
antes ou depois:

{{
  "matched_source": "nome do arquivo do documento usado como base (ou null se nenhum)",
  "probable_root_cause": "causa raiz provavel, em uma ou duas frases",
  "confidence": 0.0,
  "next_steps": ["passo 1", "passo 2", "passo 3"]
}}

"confidence" deve ser um numero entre 0.0 e 1.0, refletindo o quanto o
contexto recuperado realmente sustenta essa causa raiz. Se o contexto
nao for relevante, seja honesto e use confidence baixa (< 0.4)."""


def diagnose_node(state: CopilotState) -> CopilotState:
    llm = ChatOllama(model=LLM_MODEL, temperature=0.0)
    prompt = _build_diagnosis_prompt(state)
    response = llm.invoke(prompt)
    raw = response.content.strip()

    # tolera o modelo envolvendo o JSON em ```json ... ```
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.startswith("json"):
            raw = raw[4:]
        raw = raw.strip()

    try:
        diagnosis = json.loads(raw)
    except json.JSONDecodeError:
        diagnosis = {
            "probable_root_cause": "Nao foi possivel estruturar a resposta do modelo.",
            "confidence": 0.0,
            "next_steps": [f"Resposta bruta do modelo: {raw[:500]}"],
        }

    return {"diagnosis": diagnosis}


def report_node(state: CopilotState) -> CopilotState:
    diagnosis = state.get("diagnosis", {})
    sources = ", ".join(
        sorted({h["source"] for h in state.get("retrieved_context", [])})
    ) or "nenhuma fonte relevante encontrada"

    next_steps_md = "\n".join(
        f"- {step}" for step in diagnosis.get("next_steps", [])
    )

    matched = diagnosis.get("matched_source") or "nenhum documento especifico identificado"

    report = f"""## Diagnostico do Incidente

**Descricao reportada:** {state['description']}

**Causa raiz provavel:** {diagnosis.get('probable_root_cause', 'N/A')}

**Confianca:** {diagnosis.get('confidence', 0.0):.0%}

**Documento usado como base:** {matched}

**Proximos passos:**
{next_steps_md if next_steps_md else '- (nenhum passo sugerido)'}

**Fontes recuperadas (candidatas):** {sources}
"""
    return {"report_markdown": report}


def build_graph():
    graph = StateGraph(CopilotState)
    graph.add_node("retrieve", retrieve_node)
    graph.add_node("diagnose", diagnose_node)
    graph.add_node("report", report_node)

    graph.set_entry_point("retrieve")
    graph.add_edge("retrieve", "diagnose")
    graph.add_edge("diagnose", "report")
    graph.add_edge("report", END)

    return graph.compile()


_compiled_graph = None


def get_graph():
    global _compiled_graph
    if _compiled_graph is None:
        _compiled_graph = build_graph()
    return _compiled_graph


def run_diagnosis(request: IncidentRequest) -> DiagnosisResponse:
    initial_state: CopilotState = {
        "description": request.description,
        "logs": request.logs,
        "payload": request.payload,
    }
    final_state = get_graph().invoke(initial_state)
    diagnosis = final_state.get("diagnosis", {})

    return DiagnosisResponse(
        probable_root_cause=diagnosis.get("probable_root_cause", "N/A"),
        confidence=float(diagnosis.get("confidence", 0.0)),
        next_steps=diagnosis.get("next_steps", []),
        report_markdown=final_state.get("report_markdown", ""),
        matched_source=diagnosis.get("matched_source"),
    )


if __name__ == "__main__":
    import sys

    description = " ".join(sys.argv[1:]) or "iFlow falhando com HTTP 401 ao chamar endpoint externo"
    result = run_diagnosis(IncidentRequest(description=description))
    print(result.report_markdown)
GRAPHEOF

echo "=== 2/3 - Atualizando app/main.py com o endpoint /diagnose ==="
cat > app/main.py << 'MAINEOF'
"""SAP Integration Copilot - entrypoint FastAPI.

Recebe descricao de um incidente de integracao SAP, orquestra o
diagnostico (RAG + agente via LangGraph) e retorna causa raiz
sugerida, proximos passos e relatorio em Markdown.
"""
from fastapi import FastAPI

from app.agent.graph import run_diagnosis
from app.models import DiagnosisResponse, IncidentRequest

app = FastAPI(
    title="SAP Integration Copilot",
    description="Assistente de IA para diagnostico de incidentes de integracao SAP",
    version="0.1.0",
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/diagnose", response_model=DiagnosisResponse)
def diagnose(request: IncidentRequest) -> DiagnosisResponse:
    return run_diagnosis(request)
MAINEOF

echo "=== 3/3 - Sync das dependencias ==="
uv sync

echo
echo "============================================================"
echo "Grafo LangGraph criado e ligado ao endpoint /diagnose."
echo
echo "Teste direto pelo terminal (sem subir a API):"
echo "  uv run python -m app.agent.graph \"iFlow falhando com erro 401\""
echo
echo "Ou suba a API e teste via HTTP:"
echo "  uv run uvicorn app.main:app --reload"
echo "  curl -X POST http://localhost:8000/diagnose \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"description\": \"iFlow falhando com timeout ao consumir OData\"}'"
echo "============================================================"
