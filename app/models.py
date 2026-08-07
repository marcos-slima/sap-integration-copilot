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
