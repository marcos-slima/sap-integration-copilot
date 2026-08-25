"""Testes da camada HTTP (FastAPI)."""

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_endpoint():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.integration
def test_diagnose_endpoint_known_case():
    response = client.post("/diagnose", json={"description": "iFlow falhando com erro 401"})
    assert response.status_code == 200
    body = response.json()
    assert body["matched_source"] == "cpi_http_401.md"
    assert body["confidence"] >= 0.5
    assert "report_markdown" in body


@pytest.mark.integration
def test_diagnose_endpoint_rejects_oversized_description():
    huge_description = "x" * 10_000
    response = client.post("/diagnose", json={"description": huge_description})
    assert response.status_code == 422
