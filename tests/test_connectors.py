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
