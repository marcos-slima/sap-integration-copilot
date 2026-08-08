# Proposta: Camada de Interoperabilidade A2A para o SAP Integration Copilot

> **Status:** Arquivada para implementação futura — priorizado primeiro o
> fechamento dos conectores SAP (núcleo diferenciador do Copilot).
> Revisar quando os conectores estiverem estáveis, ou quando a GA
> inbound do Joule A2A (Q4/2026) se aproximar.

## Contexto

O Copilot já está funcional (RAG + LangGraph, 4/4 casos de teste
validados). A arquitetura da SAP oficializa dois protocolos
complementares para agentes de IA:

- **MCP** — acesso a ferramentas/dados (uso interno do Joule a
  capacidades SAP)
- **A2A (Agent2Agent)** — interoperabilidade externa entre agentes,
  caminho preferido da SAP para conectar agentes pro-code externos ao
  ecossistema Joule

## Correção importante em relação à proposta original

O suporte A2A do Joule hoje é **unidirecional (outbound)**: o Joule já
consegue chamar um agente externo via Agent Card. A direção
**inbound** — um orquestrador externo (ou um agente pro-code, como
este Copilot) sendo chamado pelo Joule como par — ainda **não é GA**;
o Agent Gateway que habilita isso está pré-GA, com disponibilidade
geral prevista para Q4/2026.

Ou seja: implementar um servidor A2A no Copilot hoje é **compatível
com o protocolo aberto** (A2A é um padrão vendor-neutral, mantido pela
Linux Foundation, independente do cronograma de GA da SAP) e deixa o
projeto **pronto para a GA inbound do Joule**, mas não deve ser
apresentado como "já consumível pelo Joule hoje" — essa parte
específica (Joule descobrindo/chamando agentes externos como
sub-agentes) ainda depende da GA de Q4/2026.

## Objetivo

Adicionar uma camada A2A **em paralelo** ao endpoint FastAPI
existente, sem alterar o núcleo (grafo LangGraph, RAG, conectores).

## O que NÃO muda

- Grafo LangGraph (retrieve → diagnose → report)
- Pipeline RAG (Qdrant + embeddings Ollama)
- Conectores SAP (OData/RFC)
- Lógica de diagnóstico e geração do relatório Markdown

## Componentes novos (módulo `app/a2a/`)

1. **Agent Card** (`agent_card.py`) — JSON descrevendo a capacidade
   "diagnosticar incidente de integração SAP": nome, descrição,
   skills, requisitos de auth, endpoint
2. **Task manager assíncrono** (`task_manager.py`) — traduz o ciclo de
   vida de task A2A (`submitted` → `working` → `completed`/`failed`)
   em chamadas internas ao grafo LangGraph existente; devolve o
   relatório como *artifact* da task
3. **Servidor A2A** (`server.py`) — expõe o endpoint A2A
   (HTTP(S)/JSON-RPC 2.0) que coexiste com o `/diagnose` do FastAPI,
   ambos chamando a mesma orquestração por trás
4. **Autenticação** — OAuth2/JWT básico entre agentes (simplificado
   para fins de portfólio/demo, documentado como gap de produção)

## Padrão arquitetural

Adapter pattern: a camada A2A isola o protocolo (ainda em evolução
até o GA) da lógica de negócio, evitando acoplamento prematuro.

## Critério de aceite

- Agent Card publicado e válido
- Task A2A de diagnóstico executa o grafo LangGraph e retorna o mesmo
  relatório Markdown já validado nos 4 casos de teste, agora como
  artifact A2A
- FastAPI `/diagnose` continua funcionando sem alteração (regressão
  zero) — **pré-requisito real**: existir suíte de testes automatizada
  (pytest) que verifique isso mecanicamente, não só manualmente
- Riscos a validar antes de iniciar: maturidade das SDKs Python para
  A2A (protocolo tem pouco mais de um ano de existência)

## Onde entra no roteiro

Extensão das Fases 4/6 do plano de aprendizado (LangChain/LangGraph/
MCP → integração final), sem impacto nas fases anteriores já
concluídas. Recomendado entrar **depois** dos conectores SAP e da
suíte de testes automatizada.
