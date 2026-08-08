# IDoc Status 51 - Application Document Not Posted

## Sintoma
IDoc fica travado com status 51 na fila de entrada (transacao WE02/BD87).
O documento de aplicacao (ex: pedido de compra, fatura) nao e criado no
sistema de destino.

## Causas comuns
- Dados mestre incompletos ou inconsistentes no sistema receptor
  (ex: centro de custo inexistente, material nao cadastrado)
- Erro de mapeamento de campos entre o segmento do IDoc e a estrutura
  de dados esperada pela BAPI/funcao de processamento
- Autorizacao insuficiente do usuario tecnico usado no processamento
  em background

## Diagnostico
1. Verificar o texto de erro completo em WE02, aba "Status Records"
2. Identificar a funcao de processamento do IDoc e rodar em modo
   debug com o mesmo payload
3. Confirmar existencia dos dados mestre referenciados no IDoc

## Resolucao tipica
Corrigir o dado mestre ou o mapeamento, e reprocessar o IDoc via
BD87 (reprocessamento manual) ou aguardar o job de reprocessamento
automatico (RBDAPP01), se configurado.
