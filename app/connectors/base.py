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
    source_system: str  # "OData" | "RFC" | outros
    status: str  # "ok" | "error"
    error_code: str | None
    message: str
    raw: str  # payload/log bruto simulado
    is_mock: bool = True
    is_fallback: bool = False  # True quando o identificador nao foi reconhecido
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
