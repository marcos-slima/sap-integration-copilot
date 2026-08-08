"""Modelos Pydantic do SAP Integration Copilot."""

from typing import Literal

from pydantic import BaseModel


class IncidentRequest(BaseModel):
    description: str
    logs: str | None = None
    payload: str | None = None
    interface_type: Literal["odata", "rfc"] | None = None
    identifier: str | None = None  # ex: nome do iFlow, RFC destination, numero de IDoc


class DiagnosisResponse(BaseModel):
    probable_root_cause: str
    confidence: float
    next_steps: list[str]
    report_markdown: str
    matched_source: str | None = None
