"""SAP Integration Copilot - entrypoint FastAPI."""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from langfuse import get_client

from app.agent.graph import run_diagnosis
from app.models import DiagnosisResponse, IncidentRequest


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    get_client().flush()


app = FastAPI(
    title="SAP Integration Copilot",
    description="Assistente de IA para diagnostico de incidentes de integracao SAP",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/diagnose", response_model=DiagnosisResponse)
def diagnose(request: IncidentRequest) -> DiagnosisResponse:
    return run_diagnosis(request)
