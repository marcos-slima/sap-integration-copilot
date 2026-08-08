# CPI iFlow - Erro HTTP 401 (Unauthorized)

## Sintoma
iFlow no Integration Suite (CPI) recebe HTTP 401 ao chamar um
endpoint externo (ex: API REST de terceiro, ou outro sistema SAP).

## Causas comuns
- Credencial armazenada no Security Material expirada ou incorreta
- Token OAuth2 expirado e o adapter nao configurado para renovacao
  automatica
- Mudanca de senha/credencial no destino nao propagada para o
  Security Material do CPI

## Diagnostico
1. Verificar o Security Material usado no adapter (Credential Name)
2. Testar a credencial isoladamente fora do iFlow
3. Checar se o tipo de autenticacao configurado corresponde ao
   exigido pelo endpoint de destino

## Resolucao tipica
Atualizar a credencial no Security Material, ou reconfigurar o
fluxo OAuth2 se o token nao estiver sendo renovado automaticamente.
