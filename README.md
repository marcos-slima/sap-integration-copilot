# SAP Integration Copilot

Assistente de IA para diagnóstico de incidentes de integração SAP.
Recebe a descrição de um incidente, lê logs/payloads, consulta um
catálogo de APIs/documentos via RAG, identifica o provável ponto de
falha, sugere causa raiz e próximos passos, e gera um relatório em
Markdown.

## Arquitetura

```
Frontend/API client
      │
      ▼
   FastAPI
      │
      ▼
Orquestração via LangGraph
      │
   ┌──┴───────────────────────┐
   ▼                          ▼
RAG Retriever          Conectores SAP
(PDF/MD/CSV)            (OData/RFC)
   │                          │
   └──────────┬───────────────┘
              ▼
         LLM / Agente
              │
              ▼
   Resposta + Relatório Markdown
```

## Stack

- **API**: FastAPI + Pydantic
- **Orquestração**: LangGraph
- **RAG**: LangChain + Qdrant (vector store) + Neo4j (grafo de
  relacionamento entre interfaces/documentos)
- **Observabilidade**: Langfuse (tracing de todo o fluxo do agente)
- **LLM local**: Ollama (qwen2.5-coder / qwen3)
- **Conectores SAP**: OData / RFC

## Desenvolvimento local

```bash
uv sync
uv run uvicorn app.main:app --reload
```

Pré-requisitos: stack Docker local (Qdrant + Neo4j + Langfuse) rodando
em `~/ai-stack`, Ollama ativo.

## Status

Projeto em desenvolvimento — portfólio da trilha SAP Architect → AI
Architect.
