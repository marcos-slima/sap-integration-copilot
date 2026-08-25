#!/usr/bin/env bash
# ============================================================
# Corrige documentacao defasada:
#  1. docs/ferramentas-sustentacao-ecossistema.md - status de
#     gitleaks/pre-commit/GitHub Actions (gap -> em uso)
#  2. README.md - adiciona secoes 5-7 as "Decisoes de Arquitetura"
#     (Langfuse, config centralizada, seguranca/CI)
#  3. README.md - corrige mencao ao Neo4j (provisionado, nao usado
#     ainda pelo codigo)
#
# Usa correspondencia por LINHA/substring unico, nao por bloco de
# texto multi-linha - mais robusto contra diferencas de whitespace
# introduzidas por reformatacoes anteriores (ja tivemos 2 falhas
# por isso hoje).
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_stale_docs.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/3 - Atualizando status no docs/ferramentas-sustentacao-ecossistema.md ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("docs/ferramentas-sustentacao-ecossistema.md")
text = path.read_text(encoding="utf-8")
lines = text.split("\n")

replacements = [
    ("**pre-commit**", "⬜ gap", "✅ em uso"),
    ("**GitHub Actions**", "⬜ gap", "✅ em uso"),
    ("**git-secrets** ou **gitleaks**", "⬜ gap", "✅ em uso"),
]

changed = 0
for i, line in enumerate(lines):
    for marker, old_status, new_status in replacements:
        if marker in line and old_status in line:
            lines[i] = line.replace(old_status, new_status)
            changed += 1

if changed == 0:
    print("AVISO: nenhuma linha correspondeu - verifique manualmente.")
else:
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"{changed} linha(s) de status atualizada(s).")
PYEOF

echo "=== 2/3 - Adicionando nota de atualizacao na priorizacao ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("docs/ferramentas-sustentacao-ecossistema.md")
text = path.read_text(encoding="utf-8")

marker = "## Priorização sugerida"
note = (
    "\n\n> **Atualização:** os itens 1 (gitleaks), 2 (GitHub Actions) e "
    "3 (pre-commit) desta lista já foram implementados e estão em "
    "produção no repositório — ver seção \"Decisões de Arquitetura\" "
    "do README para detalhes."
)

if marker in text and "já foram implementados e estão em" not in text:
    text = text.replace(marker, marker + note, 1)
    path.write_text(text, encoding="utf-8")
    print("Nota de atualização adicionada.")
elif "já foram implementados e estão em" in text:
    print("Nota ja existe, pulando.")
else:
    print("AVISO: marcador de secao nao encontrado.")
PYEOF

echo "=== 3/3 - Corrigindo mencao ao Neo4j e adicionando secoes 5-7 ao README ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("README.md")
text = path.read_text(encoding="utf-8")

old_neo4j = "Neo4j (grafo de relacionamento entre interfaces/documentos)"
new_neo4j = (
    "Neo4j (grafo de relacionamento entre interfaces/documentos — "
    "**provisionado no Docker, ainda não usado pelo código do grafo**)"
)

if old_neo4j in text:
    text = text.replace(old_neo4j, new_neo4j, 1)
    print("Mencao ao Neo4j corrigida.")
elif "provisionado no Docker, ainda não usado" in text:
    print("Correcao do Neo4j ja aplicada, pulando.")
else:
    print("AVISO: linha do Neo4j nao encontrada - verificar manualmente.")

path.write_text(text, encoding="utf-8")
PYEOF

cat >> README.md << 'READMEEOF'

### 5. Observabilidade real com Langfuse

**Contexto:** o Langfuse estava configurado desde o início do
projeto, mas sem nenhum código realmente enviando dados para lá —
configuração presente, tracing ausente.

**Implementado:** cada node do grafo (`connector`, `retrieve`,
`diagnose`, `report`) é instrumentado com `@observe`, e a chamada ao
LLM usa o `CallbackHandler` do LangChain — capturando tempo de
execução, tokens e o payload completo de entrada/saída de cada etapa,
visível em `http://localhost:3000`.

**Bug encontrado e corrigido no processo:** em execuções via `pytest`
(diferente do CLI), o SDK não fazia `flush()` automático antes do
processo terminar — de 16 execuções de teste, só 8 traces chegavam ao
Langfuse. Corrigido com uma fixture `autouse` no `conftest.py` que
força o flush ao final da sessão de testes.

### 6. Configuração centralizada (eliminando hardcoded)

**Problema encontrado:** apesar de existir um `.env` desde o início
do projeto, o código nunca o lia — URLs do Qdrant, modelo do LLM e
outras configurações estavam fixas como constantes Python, espalhadas
em múltiplos arquivos. Trocar de modelo exigia editar código-fonte
(`sed` direto no arquivo), não mudar uma variável de ambiente.

**Solução:** `app/config.py`, uma classe `Settings` (via
`pydantic-settings`) como única fonte de verdade, lida do `.env`. Um
comando (`uv run python -m app.config`) imprime a configuração
efetiva a qualquer momento, com segredos mascarados — permite
verificar o que está realmente configurado sem depender de leitura de
código-fonte.

### 7. Segurança e CI antes da publicação

Antes de tornar o repositório público:

- **`gitleaks`**: varredura de **todo o histórico do git** (não só o
  estado atual) em busca de segredos vazados — confirmado limpo antes
  do primeiro push
- **`pre-commit`**: hooks automáticos (lint/format via `ruff`,
  detecção de segredo, bloqueio de arquivo grande >5MB) rodando em
  todo commit local, dali em diante
- **GitHub Actions**: workflow de CI rodando lint + testes unitários
  a cada push/PR — o badge de status no topo deste README reflete o
  resultado real da última execução, não uma alegação

READMEEOF

echo
echo "============================================================"
echo "Documentacao atualizada:"
echo "  - docs/ferramentas-sustentacao-ecossistema.md: status corrigido"
echo "  - README.md: secoes 5-7 adicionadas, mencao ao Neo4j corrigida"
echo
echo "Revise visualmente antes de comitar:"
echo "  cat README.md | tail -60"
echo "  grep -A2 'pre-commit\\|GitHub Actions\\|gitleaks' docs/ferramentas-sustentacao-ecossistema.md"
echo
echo "Commit:"
echo "  git add README.md docs/ferramentas-sustentacao-ecossistema.md"
echo "  git commit -m 'docs: atualiza documentacao defasada (tracing, config, seguranca/CI)'"
echo "  git push"
echo "============================================================"
