#!/usr/bin/env bash
# ============================================================
# Cria a suite de testes pytest do SAP Integration Copilot:
#   - test_connectors.py : unitario, rapido, sem dependencias externas
#   - test_retriever.py  : integracao, precisa de Qdrant + Ollama (embeddings)
#   - test_graph_e2e.py  : integracao, precisa da stack completa + LLM
#
# Testes de integracao sao pulados automaticamente (nao falham) se a
# stack local (Qdrant/Ollama) nao estiver no ar - ver conftest.py.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_pytest_suite.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/5 - Adicionando dependencias de dev ==="
uv add --dev pytest httpx

echo "=== 2/5 - Configurando markers no pyproject.toml ==="
if ! grep -q "\[tool.pytest.ini_options\]" pyproject.toml; then
  cat >> pyproject.toml << 'PYTESTEOF'

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = [
    "integration: requer stack local viva (Qdrant/Ollama); pulado automaticamente se indisponivel",
]
PYTESTEOF
  echo "Bloco [tool.pytest.ini_options] adicionado."
else
  echo "[tool.pytest.ini_options] ja existe, pulando."
fi

echo "=== 3/5 - Criando tests/conftest.py (skip automatico de integracao) ==="
cat > tests/conftest.py << 'CONFTESTEOF'
"""Configuracao compartilhada dos testes.

Testes marcados com @pytest.mark.integration sao pulados
automaticamente (nao falham) se a stack local (Qdrant e/ou Ollama)
nao estiver acessivel - isso evita falsos negativos em uma maquina
sem o ambiente de IA local rodando, e evita que o CI quebre por falta
de infraestrutura que so existe localmente.
"""
import socket

import pytest


def _port_open(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _stack_available() -> bool:
    qdrant_up = _port_open("127.0.0.1", 6333)
    ollama_up = _port_open("127.0.0.1", 11434)
    return qdrant_up and ollama_up


def pytest_collection_modifyitems(config, items):
    if _stack_available():
        return
    skip_marker = pytest.mark.skip(
        reason="Stack local (Qdrant/Ollama) indisponivel em 127.0.0.1 - "
        "rode 'docker compose up -d' em ~/ai-stack e confirme o Ollama ativo"
    )
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip_marker)
CONFTESTEOF

echo "=== 4/5 - Criando tests/test_connectors.py (unitario, rapido) ==="
cat > tests/test_connectors.py << 'TESTCONNEOF'
"""Testes unitarios dos conectores SAP mock - sem dependencias
externas, rodam em qualquer maquina, sem precisar da stack no ar.
"""
from app.connectors import get_connector
from app.connectors.odata_connector import ODataConnector
from app.connectors.rfc_connector import RFCConnector


def test_odata_connector_known_scenario():
    connector = get_connector("odata")
    assert isinstance(connector, ODataConnector)

    result = connector.fetch("CPI-401-DEMO")
    assert result.status == "error"
    assert result.error_code == "401"
    assert "Unauthorized" in result.message
    assert result.is_mock is True


def test_odata_connector_unknown_identifier_returns_safe_fallback():
    connector = get_connector("odata")
    result = connector.fetch("ID-QUE-NAO-EXISTE")

    # nao deve inventar um cenario especifico - deve cair no fallback
    # generico e continuar marcado como mock
    assert result.is_mock is True
    assert result.error_code == "500"


def test_rfc_connector_known_scenarios():
    connector = get_connector("rfc")
    assert isinstance(connector, RFCConnector)

    conn_refused = connector.fetch("RFC-CONN-REFUSED-DEMO")
    assert conn_refused.error_code == "RFC_COMMUNICATION_FAILURE"

    idoc_51 = connector.fetch("RFC-IDOC-51-DEMO")
    assert idoc_51.error_code == "51"
    assert "material" in idoc_51.raw.lower()


def test_get_connector_invalid_type_raises():
    import pytest

    with pytest.raises(ValueError):
        get_connector("soap")  # tipo nao suportado
TESTCONNEOF

echo "=== 5/5 - Criando tests/test_retriever.py e tests/test_graph_e2e.py (integracao) ==="
cat > tests/test_retriever.py << 'TESTRETRIEVEREOF'
"""Testes de integracao do retriever RAG - precisam de Qdrant vivo
com a collection sap_incident_docs ja indexada (ver README/manual).
"""
import pytest

from app.rag.retriever import retrieve


@pytest.mark.integration
@pytest.mark.parametrize(
    "query,expected_source,min_score",
    [
        ("erro 401 no iFlow", "cpi_http_401.md", 0.6),
        ("iFlow travando ao consumir OData sem retorno", "odata_timeout_cpi.md", 0.6),
        ("IDoc parado com status 51", "idoc_status_51.md", 0.6),
        ("SM59 dando erro de conexao recusada", "rfc_connection_refused.md", 0.6),
    ],
)
def test_retriever_finds_correct_document(query, expected_source, min_score):
    hits = retrieve(query, target="incidents", top_k=3)
    assert hits, f"Nenhum resultado para a query: {query}"

    top = hits[0]
    assert top["source"] == expected_source, (
        f"Esperado '{expected_source}' como top-1 para '{query}', "
        f"veio '{top['source']}'"
    )
    assert top["score"] >= min_score
TESTRETRIEVEREOF

cat > tests/test_graph_e2e.py << 'TESTGRAPHEOF'
"""Testes de integracao end-to-end do grafo LangGraph completo:
conector -> retrieve -> diagnose -> report.

Precisam da stack completa: Qdrant (com sap_incident_docs indexada) e
Ollama (com o modelo LLM_MODEL e nomic-embed-text baixados).

Formaliza os 7 cenarios validados manualmente durante o
desenvolvimento, incluindo o caso de seguranca do identificador
desconhecido (nao deve alucinar um diagnostico especifico).
"""
import pytest

from app.agent.graph import run_diagnosis
from app.models import IncidentRequest


@pytest.mark.integration
@pytest.mark.parametrize(
    "description,interface_type,identifier,expected_source,min_confidence",
    [
        ("iFlow falhando com erro 401", None, None, "cpi_http_401.md", 0.5),
        ("investigar falha reportada no iFlow", "odata", "CPI-401-DEMO", "cpi_http_401.md", 0.7),
        ("IDoc travado", "rfc", "RFC-IDOC-51-DEMO", "idoc_status_51.md", 0.7),
        ("SM59 não conecta", "rfc", "RFC-CONN-REFUSED-DEMO", "rfc_connection_refused.md", 0.7),
        ("iFlow travando ao consumir OData sem retorno", None, None, "odata_timeout_cpi.md", 0.5),
        ("IDoc parado com status 51", None, None, "idoc_status_51.md", 0.5),
        ("SM59 dando erro de conexão recusada", None, None, "rfc_connection_refused.md", 0.5),
    ],
)
def test_diagnosis_matches_expected_source(
    description, interface_type, identifier, expected_source, min_confidence
):
    request = IncidentRequest(
        description=description,
        interface_type=interface_type,
        identifier=identifier,
    )
    result = run_diagnosis(request)

    assert result.matched_source == expected_source, (
        f"Esperado fonte '{expected_source}' para '{description}' "
        f"(interface={interface_type}, id={identifier}), "
        f"veio '{result.matched_source}'"
    )
    assert result.confidence >= min_confidence
    assert result.probable_root_cause and result.probable_root_cause != "N/A"
    assert result.report_markdown  # relatorio nao pode vir vazio


@pytest.mark.integration
def test_unknown_identifier_does_not_hallucinate_specific_diagnosis():
    """Caso de seguranca: identificador desconhecido nao deve produzir
    um diagnostico especifico com alta confianca - o sistema deve
    reconhecer que nao tem base solida, nao inventar uma causa raiz.
    """
    request = IncidentRequest(
        description="algo estranho aconteceu",
        interface_type="odata",
        identifier="XPTO-999-NAO-EXISTE",
    )
    result = run_diagnosis(request)

    assert result.confidence < 0.6, (
        "Identificador desconhecido nao deveria gerar alta confianca "
        f"(veio {result.confidence})"
    )
TESTGRAPHEOF

echo
echo "============================================================"
echo "Suite de testes criada."
echo
echo "Rodar so os testes rapidos (sem stack, sem LLM):"
echo "  uv run pytest tests/test_connectors.py -v"
echo
echo "Rodar tudo (precisa da stack + Ollama no ar):"
echo "  uv run pytest -v"
echo
echo "Rodar so integracao:"
echo "  uv run pytest -v -m integration"
echo
echo "Se a stack estiver fora do ar, os testes de integracao sao"
echo "PULADOS (skip), nao falham - conftest.py detecta isso via socket"
echo "em 127.0.0.1:6333 (Qdrant) e 127.0.0.1:11434 (Ollama)."
echo "============================================================"
