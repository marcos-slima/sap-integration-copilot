#!/usr/bin/env bash
# ============================================================
# Adiciona secao "Decisoes de Arquitetura" ao README.md
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash append_readme_decisions.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

cat >> README.md << 'READMEEOF'

## Decisões de Arquitetura

Registro dos problemas reais encontrados durante o desenvolvimento e
como foram resolvidos — processo de engenharia, não só o resultado
final.

### 1. Alucinação por mistura de contexto

**Problema:** ao passar os 3 documentos mais relevantes (RAG top-3)
inteiros no prompt, o LLM ocasionalmente combinava causa raiz de
documentos diferentes (ex: misturava conceitos de IDoc e OData numa
única resposta), mesmo com instrução explícita para não fazer isso.

**Solução:** restringir o contexto passado ao LLM a apenas o
**documento mais relevante** (texto completo), citando os demais só
pelo nome, sem conteúdo. Eliminou a possibilidade de mistura na raiz,
por design, em vez de depender de instrução de prompt.

### 2. Não-determinismo com temperature=0

**Problema:** o mesmo prompt, rodado duas vezes com `temperature=0.0`
no Ollama, produzia respostas diferentes — incluindo uma alucinação
completa numa das execuções. `temperature=0` não garante determinismo
total sem um `seed` explícito.

**Solução:** fixar `seed=42` na chamada ao `ChatOllama`. Validado com
5 execuções idênticas seguidas do mesmo cenário antes considerado
instável.

### 3. Guardrail determinístico para dados de fallback

**Problema:** quando um conector SAP não reconhece um identificador
(cenário simulado/mock não mapeado), o LLM às vezes ainda tentava
vincular a um documento específico da base de conhecimento com
confiança moderada-alta, mesmo orientado por prompt a não fazer isso.

**Solução:** não depender só da autoavaliação do LLM para essa
propriedade de segurança. O código verifica deterministicamente se o
conector retornou um dado de fallback (`ConnectorResult.is_fallback`)
e, nesse caso, **impõe um teto de confiança (0.4)** independente do
que o modelo reportar.

### 4. Comparação formal de modelos (qwen3:30b-a3b vs qwen2.5-coder:32b)

**Contexto:** os problemas 1 e 3 acima ocorreram especificamente com
o `qwen3:30b-a3b` (MoE, ~3B parâmetros ativos). Antes de assumir que
o modelo era a causa raiz, foi feita uma comparação formal usando
[promptfoo](https://www.promptfoo.dev/), rodando o **pipeline
completo real** (conector + RAG + guardrails) contra os dois modelos,
não o LLM isolado.

**Resultado:** nos casos com correspondência clara, os dois modelos
tiveram desempenho equivalente. No caso crítico — identificador de
sistema desconhecido, sem correspondência real na base de
conhecimento — o `qwen2.5-coder:32b` reconheceu sozinho a ausência de
correspondência (`matched_source: null`), enquanto o `qwen3:30b-a3b`
tentou vincular um documento específico mesmo assim (só não virou
problema visível por causa do guardrail do item 3).

**Decisão:** `qwen2.5-coder:32b` (denso, 32B parâmetros) adotado como
modelo de produção do grafo. Validado com a suíte completa de testes
(16/16 `pytest`) após a troca. Trade-off aceito: tempo de inferência
maior (~2min49s vs ~1min20s nos 16 testes) em troca de comportamento
mais confiável sob incerteza.

READMEEOF

echo "README.md atualizado com a secao 'Decisoes de Arquitetura'."
