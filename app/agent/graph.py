"""Grafo LangGraph do SAP Integration Copilot.

Fluxo linear:

    connector -> retrieve -> diagnose -> report

Instrumentado com Langfuse: cada node vira um span (@observe), e a
chamada ao LLM é rastreada via CallbackHandler do LangChain -
tempo, tokens e custo de cada etapa ficam visiveis em
http://localhost:3000.

Uso:
    from app.agent.graph import run_diagnosis
    from app.models import IncidentRequest

    result = run_diagnosis(IncidentRequest(description="..."))
"""

import json
import os
from typing import TypedDict

from app.config import settings

# Bridge das credenciais do .env (via app.config) para as variaveis
# de ambiente que o SDK do Langfuse espera - cobre os dois nomes
# possiveis (LANGFUSE_HOST e LANGFUSE_BASE_URL), para nao depender
# de qual convencao a versao instalada do SDK usa internamente.
os.environ.setdefault("LANGFUSE_PUBLIC_KEY", settings.langfuse_public_key)
os.environ.setdefault("LANGFUSE_SECRET_KEY", settings.langfuse_secret_key)
os.environ.setdefault("LANGFUSE_HOST", settings.langfuse_host)
os.environ.setdefault("LANGFUSE_BASE_URL", settings.langfuse_host)

from langchain_ollama import ChatOllama
from langfuse import get_client, observe
from langfuse.langchain import CallbackHandler
from langgraph.graph import END, StateGraph

from app.connectors import ConnectorResult, get_connector
from app.models import DiagnosisResponse, IncidentRequest
from app.rag.retriever import retrieve

LLM_MODEL = settings.llm_model

_langfuse_handler = CallbackHandler()


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


@observe(name="connector")
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


@observe(name="retrieve")
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


@observe(name="diagnose")
def diagnose_node(state: CopilotState) -> CopilotState:
    llm = ChatOllama(model=LLM_MODEL, temperature=0.0, seed=42)
    prompt = _build_diagnosis_prompt(state)

    if state.get("debug"):
        print("=" * 60)
        print("PROMPT ENVIADO AO LLM:")
        print("=" * 60)
        print(prompt)
        print("=" * 60)

    response = llm.invoke(prompt, config={"callbacks": [_langfuse_handler]})
    raw = response.content.strip()

    if state.get("debug"):
        print("RESPOSTA BRUTA DO LLM:")
        print("=" * 60)
        print(raw)
        print("=" * 60)

    if raw.startswith("```"):
        raw = raw.strip("`")
        raw = raw.removeprefix("json")
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


@observe(name="report")
def report_node(state: CopilotState) -> CopilotState:
    diagnosis = state.get("diagnosis", {})
    sources = (
        ", ".join(sorted({h["source"] for h in state.get("retrieved_context", [])}))
        or "nenhuma fonte relevante encontrada"
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
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Mostra o prompt exato enviado ao LLM e a resposta bruta",
    )
    args = parser.parse_args()

    description = (
        " ".join(args.description) or "iFlow falhando com HTTP 401 ao chamar endpoint externo"
    )
    request = IncidentRequest(
        description=description,
        interface_type=args.interface,
        identifier=args.identifier,
    )
    result = run_diagnosis(request, debug=args.debug)
    print(result.report_markdown)

    # Processo curto (CLI) - precisa flush manual para garantir que o
    # trace chegue ao Langfuse antes do processo terminar.
    get_client().flush()
