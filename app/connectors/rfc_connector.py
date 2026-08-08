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
