#!/usr/bin/env bash
# ============================================================
# Adiciona secao "Ferramentas de Desenvolvimento (dia a dia)" ao
# docs/ferramentas-sustentacao-ecossistema.md
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash append_dev_tools.sh
# ============================================================
set -e

TARGET="docs/ferramentas-sustentacao-ecossistema.md"

if [ ! -f "$TARGET" ]; then
  echo "ERRO: $TARGET nao encontrado. Coloque o arquivo em docs/ primeiro."
  exit 1
fi

cat >> "$TARGET" << 'DEVEOF'

## 12. Ferramentas de Desenvolvimento (dia a dia)

Complementam a lista acima (que é sustentação/operação) com o que
realmente se usa na hora de escrever código, depurar e experimentar.
Itens já cobertos nas seções anteriores (`uv`, `ruff`, `pytest`,
`promptfoo`, Claude Code) não se repetem aqui.

### Editor / IDE

| Ferramenta | Status | Propósito |
|---|---|---|
| **VS Code** | ✅ já instalado na máquina | Editor principal — extensões recomendadas abaixo |
| Extensão **Python** + **Pylance** | ⬜ gap | Autocomplete, navegação de código, checagem de tipos inline |
| Extensão **Ruff** | ⬜ gap | Lint/format em tempo real no editor, usando o mesmo Ruff já configurado no projeto |
| Extensão **Docker** | ⬜ gap | Ver/gerenciar containers da stack (`~/ai-stack`) direto no VS Code |
| Extensão **GitLens** | ⬜ gap | Blame inline, histórico de arquivo, navegação de branches sem sair do editor |
| Extensão **Even Better TOML** | ⬜ gap | Syntax highlighting/validação pro `pyproject.toml` |
| Claude Code (dentro do Claude Desktop) | ✅ já instalado | Par de programação com acesso real ao repositório |

### Terminal e produtividade de linha de comando

| Ferramenta | Status | Propósito |
|---|---|---|
| **tmux** ou **zellij** | ⬜ gap | Manter vários painéis vivos ao mesmo tempo — `docker compose logs -f`, servidor `uvicorn`, testes — sem múltiplas janelas de terminal soltas |
| **lazygit** | ⬜ gap | TUI pra git — stage/commit/branch visualmente, mais rápido que decorar comandos pro dia a dia |
| **lazydocker** | ⬜ gap | Equivalente do lazygit pro Docker — ver logs, status e reiniciar containers da stack sem abrir o Portainer |
| **gh** (GitHub CLI) | ⬜ gap | Criar PRs, issues e releases do terminal — útil assim que o repo for público |

### Testando a API e os dados

| Ferramenta | Status | Propósito |
|---|---|---|
| **HTTPie** ou **Bruno** | ⬜ gap | Testar o `POST /diagnose` sem escrever `curl` na mão toda vez — Bruno é interessante porque salva as coleções como arquivos de texto, versionáveis no próprio repo git |
| Qdrant Dashboard | ✅ já disponível | `localhost:6333/dashboard` — inspecionar vetores/collections direto no navegador |
| Neo4j Browser | ✅ já disponível | `localhost:7474` — quando o grafo (Neo4j) passar a ser usado de fato |
| **DBeaver** | ⬜ gap | Cliente universal de banco — útil pra inspecionar o Postgres/ClickHouse por trás do Langfuse quando precisar depurar dados de trace diretamente |

### Experimentação e depuração Python

| Ferramenta | Status | Propósito |
|---|---|---|
| **IPython** | ⬜ gap | REPL Python melhor que o padrão — autocomplete, histórico, `%time` pra medir chamadas ao LLM |
| **Jupyter** | ⬜ gap | Notebooks pra experimentar prompts/chunking/embeddings de forma iterativa antes de "oficializar" no código do grafo |
| **rich** | ⬜ gap | Prints formatados/coloridos — melhora bastante a legibilidade do `--debug` que já existe no `graph.py` |
| **ipdb** | ⬜ gap | Debugger interativo (`import ipdb; ipdb.set_trace()`) quando o debugger do VS Code não for prático (ex: dentro de um container) |

### Diagramas e comunicação técnica

| Ferramenta | Status | Propósito |
|---|---|---|
| **Mermaid** | ✅ já em uso (README) | Diagramas como texto, versionáveis no markdown |
| **draw.io / diagrams.net** | ⬜ gap (opcional) | Quando o diagrama precisar de mais controle visual do que o Mermaid permite |

---

### Prioridade prática pra hoje

Se for escolher só 3 pra instalar agora: **extensão Ruff + Python no VS Code** (fecha o loop de lint/format em tempo real), **lazydocker** (visibilidade rápida da stack sem decorar comando), e **HTTPie ou Bruno** (testar o `/diagnose` sem reescrever curl toda hora). O resto entra conforme a necessidade aparecer — não vale instalar tudo de uma vez só por completude.
DEVEOF

echo "Secao 'Ferramentas de Desenvolvimento (dia a dia)' adicionada a $TARGET"
