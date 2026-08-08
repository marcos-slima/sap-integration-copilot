"""SAP Integration Copilot - entrypoint FastAPI.

Recebe descricao de um incidente de integracao SAP (opcionalmente com
interface_type/identifier para acionar um conector), orquestra o
diagnostico (conector + RAG + agente via LangGraph) e retorna causa
raiz sugerida, proximos passos e relatorio em Markdown.
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
