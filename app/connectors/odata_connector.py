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
            'WWW-Authenticate: Bearer error="invalid_token"\n'
            '{"error": "invalid_token", "error_description": "Access token expired"}'
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
