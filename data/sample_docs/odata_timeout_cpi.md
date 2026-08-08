# OData Service Timeout em iFlow (CPI / Integration Suite)

## Sintoma
iFlow no SAP Integration Suite (CPI) falha com erro de timeout ao
consumir um servico OData exposto pelo SAP S/4HANA ou ECC (via
SAP Gateway).

## Causas comuns
- Query OData sem filtro trazendo volume muito grande de dados,
  estourando o tempo padrao de timeout do adapter (geralmente 60s)
- Sistema de backend sob alta carga no horario da execucao
- Pool de conexoes HTTP esgotado no Cloud Connector (cenario hibrido)

## Diagnostico
1. Verificar o Message Processing Log (MPL) do iFlow no
   monitoramento do Integration Suite
2. Checar o tempo de resposta do servico OData isoladamente fora
   do iFlow
3. Conferir status e conexoes ativas do Cloud Connector, se aplicavel

## Resolucao tipica
Adicionar paginacao ou filtros mais seletivos na query OData, e/ou
aumentar o timeout configurado no adapter do iFlow.
