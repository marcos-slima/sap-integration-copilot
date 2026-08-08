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
