"""SAP Integration Copilot - entrypoint FastAPI.

Recebe descrição de um incidente de integração SAP, orquestra o
diagnóstico (RAG + agente via LangGraph + conectores SAP) e retorna
causa raiz sugerida, próximos passos e relatório em Markdown.
"""
from fastapi import FastAPI

app = FastAPI(
    title="SAP Integration Copilot",
    description="Assistente de IA para diagnóstico de incidentes de integração SAP",
    version="0.1.0",
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
