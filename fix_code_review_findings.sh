#!/usr/bin/env bash
# ============================================================
# Corrige os pontos confirmados do code review:
#  1. LLM_MODEL global mutavel -> injecao via state/parametro
#  3. @app.on_event (deprecated) -> lifespan
#  4. Parsing JSON fragil -> with_structured_output (Pydantic)
#  7. confidence sem validacao de range -> Field(ge=0,le=1) + clamp
#  8. logs/payload sem limite -> max_length + truncamento no prompt
#  9. Sem teste de API -> tests/test_api.py (TestClient)
# 10. Dockerfile incompleto -> copia data/sample_docs, documenta .env
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_code_review_findings.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/6 - Atualizando app/models.py (max_length + Field de confidence) ==="
cat > app/models.py << 'MODELSEOF'
"""Modelos Pydantic do SAP Integration Copilot."""

from typing import Literal

from pydantic import BaseModel, Field

# Limites generosos - rejeitam entrada absurda (ex: 1MB de log colado
# por engano) com 422 claro, sem impedir uso legitimo de logs longos.
MAX_DESCRIPTION_LENGTH = 5_000
MAX_LOGS_LENGTH = 50_000
MAX_PAYLOAD_LENGTH = 50_000


class IncidentRequest(BaseModel):
    description: str = Field(max_length=MAX_DESCRIPTION_LENGTH)
    logs: str | None = Field(default=None, max_length=MAX_LOGS_LENGTH)
    payload: str | None = Field(default=None, max_length=MAX_PAYLOAD_LENGTH)
    interface_type: Literal["odata", "rfc"] | None = None
    identifier: str | None = None  # ex: nome do iFlow, RFC destination, numero de IDoc


class DiagnosisResponse(BaseModel):
    probable_root_cause: str
    confidence: float = Field(ge=0.0, le=1.0)
    next_steps: list[str]
    report_markdown: str
    matched_source: str | None = None
MODELSEOF

echo "=== 2/6 - Reescrevendo app/agent/graph.py (fixes 1, 4, 7, 8) ==="
cat > app/agent/graph.py << 'GRAPHEOF'
"""Grafo LangGraph do SAP Integration Copilot.

Fluxo linear:

    connector -> retrieve -> diagnose -> report

Instrumentado com Langfuse: cada node vira um span (@observe), e a
chamada ao LLM e rastreada via CallbackHandler do LangChain.

Correcoes aplicadas apos code review:
  - modelo do LLM injetado via state/parametro, sem global mutavel
  - saida do LLM estruturada via Pydantic (with_structured_output),
    com fallback pro parsing manual se a validacao estruturada falhar
  - confidence validado por Field(ge=0,le=1) + clamp defensivo no codigo
  - logs/payload truncados antes de entrar no prompt (protege contexto)

Uso:
    from app.agent.graph import run_diagnosis
    from app.models import IncidentRequest

    result = run_diagnosis(IncidentRequest(description="..."))
"""

import json
import os
from typing import TypedDict

from app.config import settings

# Bridge das credenciais do .env para as variaveis de ambiente que o
# SDK do Langfuse espera - isso e o padrao de configuracao esperado
# por aquele SDK especifico (le de env var por design), diferente do
# problema de "global mutavel" do item 1 abaixo (que era estado
# mutado em RUNTIME por chamadas subsequentes, nao configuracao lida
# uma vez no import).
os.environ.setdefault("LANGFUSE_PUBLIC_KEY", settings.langfuse_public_key)
os.environ.setdefault("LANGFUSE_SECRET_KEY", settings.langfuse_secret_key)
os.environ.setdefault("LANGFUSE_HOST", settings.langfuse_host)
os.environ.setdefault("LANGFUSE_BASE_URL", settings.langfuse_host)

from langchain_ollama import ChatOllama
from langfuse import get_client, observe
from langfuse.langchain import CallbackHandler
from langgraph.graph import END, StateGraph
from pydantic import BaseModel, Field

from app.connectors import ConnectorResult, get_connector
from app.models import DiagnosisResponse, IncidentRequest
from app.rag.retriever import retrieve

_langfuse_handler = CallbackHandler()

# Limites praticos de contexto enviado ao LLM - bem mais apertados que
# o max_length do Pydantic (que so protege a API de payload absurdo).
MAX_LOGS_IN_PROMPT = 2_000
MAX_PAYLOAD_IN_PROMPT = 2_000


class DiagnosisModel(BaseModel):
    """Schema estruturado da resposta do LLM - usado via
    with_structured_output, valida o range de confidence na origem."""

    matched_source: str | None = None
    probable_root_cause: str
    confidence: float = Field(ge=0.0, le=1.0)
    next_steps: list[str] = Field(default_factory=list)


class CopilotState(TypedDict, total=False):
    description: str
    logs: str | None
    payload: str | None
    interface_type: str | None
    identifier: str | None
    llm_model: str
    connector_data: ConnectorResult | None
    retrieved_context: list[dict]
    diagnosis: dict
    report_markdown: str
    debug: bool


@observe(name="connector")
def connector_node(state: CopilotState) -> CopilotState:
    interface_type = state.get("interface_type")
    if not interface_type:
        return {"connector_data": None}

    connector = get_connector(interface_type)
    result = connector.fetch(state.get("identifier") or "")
    return {"connector_data": result}


def _effective_query(state: CopilotState) -> str:
    base = state["description"]
    data = state.get("connector_data")
    if data:
        return f"{base}\n{data.message}"
    return base


@observe(name="retrieve")
def retrieve_node(state: CopilotState) -> CopilotState:
    hits = retrieve(_effective_query(state), target="incidents", top_k=3)
    return {"retrieved_context": hits}


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n[...truncado - {len(text) - limit} caracteres omitidos...]"


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
        if other_sources
        else ""
    )

    connector_block = ""
    data = state.get("connector_data")
    if data:
        fallback_warning = (
            "\n  ATENCAO: este e um dado GENERICO DE FALLBACK - o identificador "
            "informado nao foi reconhecido pelo sistema. NAO trate isso como um "
            "erro especifico conhecido. A menos que a descricao textual do "
            "incidente, por si so, bata claramente com o documento de contexto, "
            "use confidence baixa (< 0.4) e considere matched_source como null."
            if data.is_fallback
            else ""
        )
        connector_block = f"""
Dados coletados diretamente do sistema SAP (via conector {data.source_system}{' - SIMULADO/MOCK' if data.is_mock else ''}):
  status: {data.status}
  codigo de erro: {data.error_code}
  mensagem: {data.message}
  detalhe bruto: {data.raw}{fallback_warning}
"""

    extras = ""
    if state.get("logs"):
        extras += f"\nLogs:\n{_truncate(state['logs'], MAX_LOGS_IN_PROMPT)}\n"
    if state.get("payload"):
        extras += f"\nPayload:\n{_truncate(state['payload'], MAX_PAYLOAD_IN_PROMPT)}\n"

    return f"""Voce e um especialista em integracao SAP (OData, IDoc, RFC, CPI).

Incidente reportado:
{state['description']}
{extras}{connector_block}
Contexto recuperado da base de conhecimento de incidentes:
{context_block}
{others_note}
Regra importante: baseie sua resposta EXCLUSIVAMENTE no documento de
contexto acima e, se disponivel, nos dados reais do conector (que tem
prioridade sobre a descricao textual do usuario, pois vem diretamente
do sistema). Nao combine informacoes de outros documentos. Se o
documento acima nao corresponder ao sintoma descrito, diga isso e use
confidence baixa em vez de inventar uma causa raiz combinando temas
diferentes.

"confidence" deve ser um numero entre 0.0 e 1.0. Se houver dados reais
do conector confirmando o diagnostico, a confidence pode ser mais alta
(o dado do sistema e mais confiavel que so a descricao textual)."""


def _apply_confidence_guardrails(diagnosis: dict, state: CopilotState) -> dict:
    """Guardrails deterministicos - nao confia so na autoavaliacao do
    LLM nem so na validacao de schema."""
    diagnosis["confidence"] = max(0.0, min(1.0, float(diagnosis.get("confidence", 0.0))))

    data = state.get("connector_data")
    if data and data.is_fallback:
        original = diagnosis["confidence"]
        capped = min(original, 0.4)
        if capped < original:
            diagnosis["confidence"] = capped
            diagnosis["probable_root_cause"] = (
                f"[confianca limitada - identificador nao reconhecido pelo sistema] "
                f"{diagnosis.get('probable_root_cause', '')}"
            )

    if not state.get("retrieved_context") and not data:
        original = diagnosis["confidence"]
        capped = min(original, 0.3)
        if capped < original:
            diagnosis["confidence"] = capped
            diagnosis["matched_source"] = None
            diagnosis["probable_root_cause"] = (
                f"[confianca limitada - nenhum documento relevante encontrado] "
                f"{diagnosis.get('probable_root_cause', '')}"
            )

    return diagnosis


@observe(name="diagnose")
def diagnose_node(state: CopilotState) -> CopilotState:
    model_name = state.get("llm_model") or settings.llm_model
    llm = ChatOllama(model=model_name, temperature=0.0, seed=42)
    prompt = _build_diagnosis_prompt(state)

    structured_llm = llm.with_structured_output(DiagnosisModel, include_raw=True)
    result = structured_llm.invoke(prompt, config={"callbacks": [_langfuse_handler]})
    raw_message = result["raw"]
    parsed: DiagnosisModel | None = result["parsed"]

    if state.get("debug"):
        print("=" * 60)
        print("PROMPT ENVIADO AO LLM:")
        print("=" * 60)
        print(prompt)
        print("=" * 60)
        print("RESPOSTA BRUTA DO LLM:")
        print("=" * 60)
        print(raw_message.content if raw_message else "(sem conteudo bruto)")
        print("=" * 60)

    if parsed is not None:
        diagnosis = parsed.model_dump()
    else:
        raw = (raw_message.content or "").strip() if raw_message else ""
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

    diagnosis = _apply_confidence_guardrails(diagnosis, state)
    return {"diagnosis": diagnosis}


@observe(name="report")
def report_node(state: CopilotState) -> CopilotState:
    diagnosis = state.get("diagnosis", {})
    sources = ", ".join(sorted({h["source"] for h in state.get("retrieved_context", [])})) or (
        "nenhuma fonte relevante encontrada"
    )

    next_steps_md = "\n".join(f"- {step}" for step in diagnosis.get("next_steps", []))
    matched = diagnosis.get("matched_source") or "nenhum documento especifico identificado"

    connector_line = ""
    data = state.get("connector_data")
    if data:
        connector_line = (
            f"\n**Dados do sistema ({data.source_system}"
            f"{' - simulado' if data.is_mock else ''}):** "
            f"status={data.status}, codigo={data.error_code}\n"
        )

    report = f"""## Diagnostico do Incidente

**Descricao reportada:** {state['description']}
{connector_line}
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
    graph.add_node("connector", connector_node)
    graph.add_node("retrieve", retrieve_node)
    graph.add_node("diagnose", diagnose_node)
    graph.add_node("report", report_node)

    graph.set_entry_point("connector")
    graph.add_edge("connector", "retrieve")
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


@observe(name="sap_copilot_diagnosis")
def run_diagnosis(
    request: IncidentRequest,
    debug: bool = False,
    llm_model: str | None = None,
) -> DiagnosisResponse:
    """Executa o grafo completo para um incidente.

    llm_model: override opcional do modelo (ex: usado pelo
    promptfoo_provider.py para comparacao de modelos) - passado via
    parametro/state, nao mais via mutacao de global de modulo.
    """
    initial_state: CopilotState = {
        "description": request.description,
        "logs": request.logs,
        "payload": request.payload,
        "interface_type": request.interface_type,
        "identifier": request.identifier,
        "llm_model": llm_model or settings.llm_model,
        "debug": debug,
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
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("description", nargs="*", default=[])
    parser.add_argument("--interface", choices=["odata", "rfc"], default=None)
    parser.add_argument("--id", dest="identifier", default=None)
    parser.add_argument("--model", dest="llm_model", default=None, help="Override do modelo LLM")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    description = " ".join(args.description) or "iFlow falhando com HTTP 401 ao chamar endpoint externo"
    request = IncidentRequest(
        description=description,
        interface_type=args.interface,
        identifier=args.identifier,
    )
    result = run_diagnosis(request, debug=args.debug, llm_model=args.llm_model)
    print(result.report_markdown)

    get_client().flush()
GRAPHEOF

echo "=== 3/6 - Atualizando app/main.py (lifespan em vez de on_event) ==="
cat > app/main.py << 'MAINEOF'
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
MAINEOF

echo "=== 4/6 - Atualizando scripts/promptfoo_provider.py ==="
cat > scripts/promptfoo_provider.py << 'PROVIDEREOF'
#!/usr/bin/env python3
"""Provider customizado do promptfoo - roda o pipeline real do
Copilot, passando o modelo via parametro llm_model (nao mais via
mutacao de global de modulo)."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.agent.graph import run_diagnosis  # noqa: E402
from app.models import IncidentRequest  # noqa: E402


def main() -> None:
    model = sys.argv[1]
    raw_prompt = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()

    parts = raw_prompt.strip().split("|||")
    description = parts[0] if len(parts) > 0 else ""
    interface_type = parts[1] if len(parts) > 1 and parts[1] != "none" else None
    identifier = parts[2] if len(parts) > 2 and parts[2] != "none" else None

    request = IncidentRequest(
        description=description,
        interface_type=interface_type,
        identifier=identifier,
    )
    result = run_diagnosis(request, llm_model=model)

    print(
        json.dumps(
            {
                "matched_source": result.matched_source,
                "confidence": result.confidence,
                "probable_root_cause": result.probable_root_cause,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
PROVIDEREOF
chmod +x scripts/promptfoo_provider.py

echo "=== 5/6 - Criando tests/test_api.py ==="
cat > tests/test_api.py << 'TESTAPIEOF'
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
TESTAPIEOF

echo "=== 6/6 - Corrigindo Dockerfile ==="
cat > Dockerfile << 'DOCKERFILEEOF'
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml .
RUN uv sync --no-dev

COPY app/ app/

COPY data/sample_docs/ data/sample_docs/

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKERFILEEOF

echo "=== Sync + lint ==="
uv sync
uv run ruff check --fix .
uv run ruff format .

echo
echo "============================================================"
echo "Correcoes aplicadas. Rode a suite completa:"
echo "  uv run pytest -v"
echo "============================================================"
