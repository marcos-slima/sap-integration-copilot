#!/usr/bin/env bash
# ============================================================
# Adiciona conectores SAP (OData + RFC, interface comum) e liga
# um node "connector" no inicio do grafo LangGraph, antes do
# retrieve.
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_sap_connectors.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/5 - Criando app/connectors/base.py (interface comum) ==="
cat > app/connectors/base.py << 'BASEEOF'
"""Interface comum para conectores SAP.

Todo conector (OData, RFC, e futuros como IDoc/SOAP) implementa este
contrato, permitindo que o grafo LangGraph trate qualquer sistema de
origem de forma uniforme.

NOTA: implementacoes atuais sao MOCKS — simulam respostas realistas
de sistemas SAP para fins de prototipagem/portfolio, sem depender de
acesso a um sistema real. Trocar por chamadas reais (requests para
OData, pyrfc para RFC) e um passo futuro que NAO exige mudar o
restante do grafo, gracas a essa interface comum.
"""
from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class ConnectorResult:
    source_system: str          # "OData" | "RFC" | outros
    status: str                 # "ok" | "error"
    error_code: str | None
    message: str
    raw: str                    # payload/log bruto simulado
    is_mock: bool = True
    is_fallback: bool = False   # True quando o identificador nao foi reconhecido
                                 # (dado generico, nao um cenario real mapeado)


class SAPConnector(ABC):
    """Contrato comum para qualquer conector de sistema SAP."""

    @abstractmethod
    def fetch(self, identifier: str) -> ConnectorResult:
        """Busca o estado/erro de uma interface SAP a partir de um
        identificador (ex: nome do iFlow, RFC destination, numero de
        IDoc). Implementacoes mock ignoram credenciais reais.
        """
        raise NotImplementedError
BASEEOF

echo "=== 2/5 - Criando app/connectors/odata_connector.py ==="
cat > app/connectors/odata_connector.py << 'ODATAEOF'
"""Conector OData (mock) - simula chamadas a servicos OData/CPI.

Substituir por implementacao real: usar `requests`/`httpx` contra o
endpoint OData real (SAP Gateway ou Integration Suite), com
autenticacao via Security Material/OAuth2.
"""
from app.connectors.base import ConnectorResult, SAPConnector

_MOCK_SCENARIOS: dict[str, ConnectorResult] = {
    "CPI-401-DEMO": ConnectorResult(
        source_system="OData",
        status="error",
        error_code="401",
        message="Unauthorized ao chamar endpoint externo via iFlow CPI",
        raw=(
            "HTTP/1.1 401 Unauthorized\n"
            "WWW-Authenticate: Bearer error=\"invalid_token\"\n"
            "{\"error\": \"invalid_token\", \"error_description\": \"Access token expired\"}"
        ),
    ),
    "CPI-TIMEOUT-DEMO": ConnectorResult(
        source_system="OData",
        status="error",
        error_code="504",
        message="Timeout ao consumir servico OData a partir de iFlow CPI",
        raw=(
            "HTTP/1.1 504 Gateway Timeout\n"
            "MPL Status: FAILED\n"
            "Adapter: OData V2, timeout apos 60000ms, query sem $filter/$top"
        ),
    ),
}

_DEFAULT = ConnectorResult(
    source_system="OData",
    status="error",
    error_code="500",
    message="Erro generico simulado ao consumir servico OData (identificador nao reconhecido)",
    raw="HTTP/1.1 500 Internal Server Error (dados mock, identificador desconhecido)",
    is_fallback=True,
)


class ODataConnector(SAPConnector):
    def fetch(self, identifier: str) -> ConnectorResult:
        return _MOCK_SCENARIOS.get(identifier, _DEFAULT)
ODATAEOF

echo "=== 3/5 - Criando app/connectors/rfc_connector.py ==="
cat > app/connectors/rfc_connector.py << 'RFCEOF'
"""Conector RFC (mock) - simula chamadas RFC/BAPI e status de IDoc.

Substituir por implementacao real: usar `pyrfc` (SAP NetWeaver RFC
SDK) para chamadas RFC reais, e leitura de status via BAPI de
monitoramento de IDoc (ex: BAPI_IDOC_STATUS).
"""
from app.connectors.base import ConnectorResult, SAPConnector

_MOCK_SCENARIOS: dict[str, ConnectorResult] = {
    "RFC-CONN-REFUSED-DEMO": ConnectorResult(
        source_system="RFC",
        status="error",
        error_code="RFC_COMMUNICATION_FAILURE",
        message="Connection refused ao testar destino RFC via SM59",
        raw=(
            "CALL FUNCTION 'RFC_PING' DESTINATION 'DEST_QA'\n"
            "EXCEPTION: COMMUNICATION_FAILURE\n"
            "Partner '10.20.30.40:3300' not reached"
        ),
    ),
    "RFC-IDOC-51-DEMO": ConnectorResult(
        source_system="RFC",
        status="error",
        error_code="51",
        message="IDoc com status 51 - Application Document Not Posted",
        raw=(
            "IDOC: 0000000001234567\n"
            "STATUS: 51\n"
            "MESSAGE: Erro ao criar documento de aplicacao - "
            "material 4711 nao cadastrado no centro 1000"
        ),
    ),
}

_DEFAULT = ConnectorResult(
    source_system="RFC",
    status="error",
    error_code="RFC_ERROR",
    message="Erro generico simulado em chamada RFC (identificador nao reconhecido)",
    raw="RFC call failed (dados mock, identificador desconhecido)",
    is_fallback=True,
)


class RFCConnector(SAPConnector):
    def fetch(self, identifier: str) -> ConnectorResult:
        return _MOCK_SCENARIOS.get(identifier, _DEFAULT)
RFCEOF

echo "=== 4/5 - Criando app/connectors/__init__.py (factory) ==="
cat > app/connectors/__init__.py << 'INITEOF'
"""Factory de conectores SAP."""
from app.connectors.base import ConnectorResult, SAPConnector
from app.connectors.odata_connector import ODataConnector
from app.connectors.rfc_connector import RFCConnector

_REGISTRY: dict[str, type[SAPConnector]] = {
    "odata": ODataConnector,
    "rfc": RFCConnector,
}


def get_connector(interface_type: str) -> SAPConnector:
    cls = _REGISTRY.get(interface_type.lower())
    if cls is None:
        raise ValueError(f"Tipo de interface desconhecido: {interface_type}")
    return cls()


__all__ = ["ConnectorResult", "SAPConnector", "ODataConnector", "RFCConnector", "get_connector"]
INITEOF

echo "=== 5/5 - Atualizando models.py, graph.py e main.py ==="
cat > app/models.py << 'MODELSEOF'
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
MODELSEOF

cat > app/agent/graph.py << 'GRAPHEOF'
"""Grafo LangGraph do SAP Integration Copilot.

Fluxo linear (v2 - com conector):

    connector -> retrieve -> diagnose -> report

  connector : se um interface_type/identifier foi informado, busca
              dados simulados do sistema SAP (OData/RFC) ANTES de
              qualquer outra coisa - representa "o que o sistema
              realmente reportou", nao so o texto digitado pelo usuario
  retrieve  : consulta a base de incidentes (Qdrant), usando a
              descricao + dados do conector (se houver) como query
  diagnose  : chama o LLM local (Ollama) com o contexto recuperado e
              os dados do conector, pede causa raiz/confianca/passos
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

from app.connectors import ConnectorResult, get_connector
from app.models import DiagnosisResponse, IncidentRequest
from app.rag.retriever import retrieve

LLM_MODEL = "qwen3:30b-a3b"


class CopilotState(TypedDict, total=False):
    description: str
    logs: str | None
    payload: str | None
    interface_type: str | None
    identifier: str | None
    connector_data: ConnectorResult | None
    retrieved_context: list[dict]
    diagnosis: dict
    report_markdown: str
    debug: bool


def connector_node(state: CopilotState) -> CopilotState:
    interface_type = state.get("interface_type")
    if not interface_type:
        return {"connector_data": None}

    connector = get_connector(interface_type)
    result = connector.fetch(state.get("identifier") or "")
    return {"connector_data": result}


def _effective_query(state: CopilotState) -> str:
    """Query usada para o retriever: combina a descricao do usuario
    com a mensagem real reportada pelo conector, se houver."""
    base = state["description"]
    data = state.get("connector_data")
    if data:
        return f"{base}\n{data.message}"
    return base


def retrieve_node(state: CopilotState) -> CopilotState:
    hits = retrieve(_effective_query(state), target="incidents", top_k=3)
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

    connector_block = ""
    data = state.get("connector_data")
    if data:
        fallback_warning = (
            "\n  ATENCAO: este e um dado GENERICO DE FALLBACK - o identificador "
            "informado nao foi reconhecido pelo sistema. NAO trate isso como um "
            "erro especifico conhecido. A menos que a descricao textual do "
            "incidente, por si so, bata claramente com o documento de contexto, "
            "use confidence baixa (< 0.4) e considere matched_source como null."
            if data.is_fallback else ""
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
        extras += f"\nLogs:\n{state['logs']}\n"
    if state.get("payload"):
        extras += f"\nPayload:\n{state['payload']}\n"

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

Responda APENAS com um JSON valido no seguinte formato, sem texto
antes ou depois:

{{
  "matched_source": "nome do arquivo do documento usado como base (ou null se nenhum)",
  "probable_root_cause": "causa raiz provavel, em uma ou duas frases",
  "confidence": 0.0,
  "next_steps": ["passo 1", "passo 2", "passo 3"]
}}

"confidence" deve ser um numero entre 0.0 e 1.0. Se houver dados reais
do conector confirmando o diagnostico, a confidence pode ser mais alta
(o dado do sistema e mais confiavel que so a descricao textual)."""


def diagnose_node(state: CopilotState) -> CopilotState:
    llm = ChatOllama(model=LLM_MODEL, temperature=0.0, seed=42)
    prompt = _build_diagnosis_prompt(state)

    if state.get("debug"):
        print("=" * 60)
        print("PROMPT ENVIADO AO LLM:")
        print("=" * 60)
        print(prompt)
        print("=" * 60)

    response = llm.invoke(prompt)
    raw = response.content.strip()

    if state.get("debug"):
        print("RESPOSTA BRUTA DO LLM:")
        print("=" * 60)
        print(raw)
        print("=" * 60)

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

    # Guardrail deterministico: nao confia so na autoavaliacao do LLM.
    # Se o conector caiu no fallback generico (identificador nao
    # reconhecido), o codigo IMPOE um teto de confianca, independente
    # do que o modelo tenha respondido.
    data = state.get("connector_data")
    if data and data.is_fallback:
        original_confidence = float(diagnosis.get("confidence", 0.0))
        capped = min(original_confidence, 0.4)
        if capped < original_confidence:
            diagnosis["confidence"] = capped
            diagnosis["probable_root_cause"] = (
                f"[confianca limitada - identificador nao reconhecido pelo sistema] "
                f"{diagnosis.get('probable_root_cause', '')}"
            )

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


def run_diagnosis(request: IncidentRequest, debug: bool = False) -> DiagnosisResponse:
    initial_state: CopilotState = {
        "description": request.description,
        "logs": request.logs,
        "payload": request.payload,
        "interface_type": request.interface_type,
        "identifier": request.identifier,
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
    parser.add_argument("--debug", action="store_true", help="Mostra o prompt exato enviado ao LLM e a resposta bruta")
    args = parser.parse_args()

    description = " ".join(args.description) or "iFlow falhando com HTTP 401 ao chamar endpoint externo"
    request = IncidentRequest(
        description=description,
        interface_type=args.interface,
        identifier=args.identifier,
    )
    result = run_diagnosis(request, debug=args.debug)
    print(result.report_markdown)
GRAPHEOF

cat > app/main.py << 'MAINEOF'
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
MAINEOF

echo "=== Sync das dependencias ==="
uv sync

echo
echo "============================================================"
echo "Conectores SAP (OData + RFC, mock, interface comum) criados"
echo "e ligados como primeiro node do grafo."
echo
echo "Testes sugeridos:"
echo
echo "1. Sem conector (comportamento anterior, so texto):"
echo "   uv run python -m app.agent.graph \"iFlow falhando com erro 401\""
echo
echo "2. Com conector OData (dados 'reais' simulados batendo com o incidente):"
echo "   uv run python -m app.agent.graph --interface odata --id CPI-401-DEMO \"investigar falha reportada no iFlow\""
echo
echo "3. Com conector RFC (IDoc):"
echo "   uv run python -m app.agent.graph --interface rfc --id RFC-IDOC-51-DEMO \"IDoc travado\""
echo
echo "4. Com conector RFC (conexao recusada):"
echo "   uv run python -m app.agent.graph --interface rfc --id RFC-CONN-REFUSED-DEMO \"SM59 nao conecta\""
echo
echo "5. Identificador desconhecido (fallback generico, mostra que o"
echo "   conector nao inventa dados fora do que foi mapeado):"
echo "   uv run python -m app.agent.graph --interface odata --id XPTO-999 \"algo estranho aconteceu\""
echo "============================================================"
