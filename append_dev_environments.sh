#!/usr/bin/env bash
# ============================================================
# Adiciona secao "Criacao e Configuracao de Ambientes de
# Desenvolvimento" ao docs/ferramentas-sustentacao-ecossistema.md
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash append_dev_environments.sh
# ============================================================
set -e

TARGET="docs/ferramentas-sustentacao-ecossistema.md"

if [ ! -f "$TARGET" ]; then
  echo "ERRO: $TARGET nao encontrado. Coloque o arquivo em docs/ primeiro."
  exit 1
fi

cat >> "$TARGET" << 'ENVEOF'

## 13. Criação e Configuração de Ambientes de Desenvolvimento

Como o projeto já gerencia bibliotecas/dependências hoje, e o que
falta pra isso ser totalmente reprodutível por qualquer pessoa (ou
por você mesmo, numa máquina nova).

### O que já está certo

- **Separação de ambientes por propósito**: `~/ai-lab` (Python de
  estudo/experimentação) é isolado de `~/sap-integration-copilot`
  (o projeto em si) — cada um com seu próprio `uv`/Python 3.12,
  sem contaminação cruzada de dependências
- **`uv` como gerenciador único**: resolve, trava e instala
  dependências de forma determinística — `pyproject.toml` declara o
  que é necessário, `uv.lock` (gerado automaticamente) trava as
  versões exatas resolvidas
- **Separação `dependencies` vs `[project.optional-dependencies].dev`**:
  o que roda em produção (`fastapi`, `langgraph` etc.) fica separado
  do que só serve pra desenvolver (`pytest`, `ruff`, `httpx`)

### Gap real encontrado durante o desenvolvimento

O `~/ai-lab/.env` foi criado desde o início do projeto, com
`QDRANT_URL`, `NEO4J_URI`, `LANGFUSE_HOST` etc. — **mas o código do
Copilot nunca leu esse arquivo**. `app/rag/ingest.py`,
`app/rag/retriever.py` e `app/agent/graph.py` têm a URL do Qdrant
(`http://127.0.0.1:6333`) e o modelo do LLM **hardcoded** como
constantes Python, direto no código.

Funciona hoje porque tudo roda na mesma máquina, com os mesmos
endereços fixos. Mas isso quebra no primeiro cenário realista de
sustentação: mover a stack pra outra máquina, apontar pra um Qdrant
remoto, ou rodar em produção com endpoints diferentes — exigiria
editar código-fonte em vários arquivos, em vez de mudar uma variável
de ambiente.

**Correção recomendada:** introduzir uma classe de configuração
tipada com `pydantic-settings`, lida uma vez a partir do `.env`:

```python
# app/config.py
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    qdrant_url: str = "http://127.0.0.1:6333"
    neo4j_uri: str = "bolt://127.0.0.1:7687"
    neo4j_user: str = "neo4j"
    neo4j_password: str = ""
    langfuse_host: str = "http://127.0.0.1:3000"
    ollama_host: str = "http://127.0.0.1:11434"
    llm_model: str = "qwen2.5-coder:32b"
    embedding_model: str = "nomic-embed-text"

    model_config = {"env_file": ".env"}

settings = Settings()
```

E então `app/rag/ingest.py`, `retriever.py` e `agent/graph.py` passam
a importar `from app.config import settings` em vez de repetir
constantes soltas. Isso também resolve, de quebra, a comparação de
modelo que fizemos via `promptfoo` — trocar de modelo vira alterar
uma variável de ambiente, não um `sed` no código-fonte.

### Reprodutibilidade — "clonei o repo numa máquina nova, e agora?"

Checklist do que precisa existir pra isso funcionar sem repetir toda
a investigação manual de hoje:

1. `uv sync` — instala exatamente as mesmas versões travadas no
   `uv.lock` (**por isso o `uv.lock` deve ser versionado no git,
   nunca ignorado**)
2. `ollama pull qwen2.5-coder:32b && ollama pull nomic-embed-text` —
   os modelos não vão junto com o `git clone`, precisam ser
   documentados como pré-requisito (candidato a entrar no `README`
   ou num script `bootstrap.sh`)
3. `docker compose up -d` em `~/ai-stack` — stack de infraestrutura
4. Copiar `.env.example` (**ainda não existe** — vale criar um,
   com os nomes das variáveis mas sem valores reais) para `.env` e
   preencher

### Estratégia de atualização de dependências

- Hoje: manual, via `uv add`/`uv sync` quando necessário
- Com **Dependabot** (já mencionado na seção 7) configurado no
  GitHub, PRs de atualização de dependência (incluindo alertas de
  segurança) passam a ser automáticos — só revisar e mergear
ENVEOF

echo "Secao 'Criacao e Configuracao de Ambientes de Desenvolvimento' adicionada a $TARGET"
