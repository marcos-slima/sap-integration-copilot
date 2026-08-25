#!/usr/bin/env bash
# ============================================================
# Corrige documentacao defasada apos o code review:
#  1. docs/TUTORIAL_ARQUITETURA_DEBUG.md - BP5/BP6 e catalogo de libs
#  2. README.md - secao 9 (achados do code review)
#  3. docs/PROCESSO_DESENVOLVIMENTO.md - nota na Fase 6
#
# Usa correspondencia por CABECALHO de secao (### BP5, ### BP6),
# nao por bloco de codigo exato - mais robusto.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_docs_after_code_review.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/3 - Corrigindo BP5/BP6 no tutorial ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("docs/TUTORIAL_ARQUITETURA_DEBUG.md")
text = path.read_text(encoding="utf-8")
lines = text.split("\n")


def find_heading(lines, heading):
    for i, line in enumerate(lines):
        if line.strip() == heading:
            return i
    return None


bp5_start = find_heading(lines, "### BP5 — Node de diagnóstico (chamada ao LLM)")
bp7_start = find_heading(lines, "### BP7 — Node de relatório")

if bp5_start is None or bp7_start is None:
    print("AVISO: cabecalhos BP5/BP7 nao encontrados - verifique manualmente.")
else:
    new_block = '''### BP5 — Node de diagnóstico (chamada ao LLM)

**Arquivo:** `app/agent/graph.py`, função `diagnose_node`

> **Atualizado após code review:** o código não usa mais `llm.invoke(prompt)`
> direto — usa `llm.with_structured_output(DiagnosisModel, include_raw=True)`,
> que valida a saída contra um schema Pydantic e retorna um **dicionário**,
> não um `AIMessage` puro.

Dois breakpoints:

**5a.** Na linha `result = structured_llm.invoke(prompt, ...)` — **antes** de executar.
- Inspecione `prompt` (string completa)
- Inspecione `llm` — confirme `model`, `temperature=0.0`, `seed=42`

**5b.** Logo depois, na linha `raw_message = result["raw"]`.
- `result` é um `dict` com duas chaves: `"raw"` (o `AIMessage` original, com `.content` em texto puro) e `"parsed"` (uma instância de `DiagnosisModel` já validada, ou `None` se a validação estruturada falhar)
- Se `parsed` vier `None`, o código cai no bloco de fallback logo abaixo (parsing manual tolerante do `raw_message.content`) — é a mesma rede de segurança de sempre, agora como *segunda* camada, não a única

**Pergunta:** "o modelo recebeu exatamente o contexto que eu esperava, e a validação estruturada (`parsed`) teve sucesso, ou caiu no fallback manual?"

### BP6 — Guardrails determinísticos

**Arquivo:** `app/agent/graph.py`, função `_apply_confidence_guardrails` (extraída de `diagnose_node` após o code review — antes ficava inline)

Três verificações em sequência, todas de código, nenhuma delas depende do LLM se autoavaliar corretamente:

1. **Clamp de range:** `diagnosis["confidence"] = max(0.0, min(1.0, ...))` — defesa em profundidade mesmo com `Field(ge=0.0, le=1.0)` já validando na origem via Pydantic
2. **Fallback do conector:** mesmo guardrail de sempre — identificador não reconhecido → teto de confiança 0.4
3. **Contexto vazio:** guardrail mais novo — se não veio nenhum documento do retriever **e** não tem dado de conector, teto de confiança 0.3, `matched_source` forçado pra `None`

**O que observar:** rode uma vez com um caso conhecido (nenhum guardrail deveria disparar), uma vez com identificador desconhecido (guardrail 2), e uma vez com uma descrição totalmente fora do domínio sem `--interface` (guardrail 3).

**Pergunta:** "quantas camadas independentes de proteção existem entre uma resposta ruim do LLM e o que chega no usuário final — e cada uma delas dispara quando deveria?"

'''
    new_lines = lines[:bp5_start] + new_block.split("\n") + lines[bp7_start:]
    Path("docs/TUTORIAL_ARQUITETURA_DEBUG.md").write_text("\n".join(new_lines), encoding="utf-8")
    print("BP5/BP6 atualizados.")
PYEOF

echo "=== 2/3 - Atualizando catalogo de bibliotecas no tutorial ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("docs/TUTORIAL_ARQUITETURA_DEBUG.md")
lines = path.read_text(encoding="utf-8").split("\n")

changed = 0
for i, line in enumerate(lines):
    if "langchain-ollama" in line and "ChatOllama(model=..." in line:
        lines[i] = line.replace(
            "`ChatOllama(model=..., temperature=0.0, seed=42).invoke(prompt)`",
            "`ChatOllama(...).with_structured_output(DiagnosisModel, include_raw=True).invoke(prompt)`",
        )
        changed += 1
    if line.strip().startswith("| **Pydantic**"):
        lines[i] = line.replace(
            '`Literal["odata", "rfc"]`',
            '`Literal["odata", "rfc"]`, `Field(ge=0, le=1)` (validação de confidence), `Field(max_length=...)` (limite de entrada), `with_structured_output` (saída do LLM validada)',
        )
        changed += 1

if changed == 0:
    print("AVISO: linhas do catalogo nao encontradas - verifique manualmente.")
else:
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"{changed} linha(s) do catalogo atualizada(s).")
PYEOF

echo "=== 3/3 - Adicionando secao 9 ao README e nota no processo ==="
if ! grep -q "with_structured_output" README.md 2>/dev/null; then
cat >> README.md << 'READMEEOF'

### 9. Achados de code review: estado global, parsing frágil, limites ausentes

Uma revisão de código externa identificou 10 pontos; a triagem separou
o que era real do que era falso alarme ou já havia sido corrigido:

- **Falso alarme:** alegação de que `report_node`/`run_diagnosis`
  estariam ausentes do arquivo — não procede, ambos existem e
  funcionam (o revisor provavelmente viu um trecho cortado, não o
  arquivo completo)
- **Já corrigido antes da revisão:** singleton no retriever e
  `ensure_collection` fora do loop de batch (ver seções anteriores)
- **Confirmados e corrigidos nesta rodada:**
  - `LLM_MODEL` como global mutável de módulo → injetado via `state`/
    parâmetro em `run_diagnosis(..., llm_model=...)`, eliminando risco
    de corrida entre execuções concorrentes
  - Parsing de JSON manual e frágil → `llm.with_structured_output(DiagnosisModel, include_raw=True)`, com o parsing manual antigo mantido como *fallback*, não mais como único caminho
  - `confidence` sem validação de range → `Field(ge=0.0, le=1.0)` no
    schema Pydantic **+** clamp defensivo no código (a mesma filosofia
    de guardrail em camadas já usada para o fallback do conector,
    agora estendida)
  - `logs`/`payload` sem limite de tamanho → `max_length` no Pydantic
    (rejeita entrada absurda na API) e truncamento mais apertado na
    montagem do prompt (protege o contexto/custo do LLM)
  - Zero teste da camada HTTP → `tests/test_api.py` com `TestClient`
  - `Dockerfile` não copiava `data/`, então o fallback de documentos
    de exemplo quebraria em produção → corrigido, com nota explícita
    de que a biblioteca de 36GB nunca deve entrar na imagem e que
    `.env` deve ser injetado em runtime, não commitado na imagem
  - `@app.on_event` (deprecated, ainda funcional mas legado) →
    migrado para o padrão `lifespan` do FastAPI
READMEEOF
echo "Secao 9 adicionada ao README."
else
  echo "Secao 9 ja existe no README, pulando."
fi

if ! grep -q "code review" docs/PROCESSO_DESENVOLVIMENTO.md 2>/dev/null; then
cat >> docs/PROCESSO_DESENVOLVIMENTO.md << 'PROCESSOEOF'

## Nota de atualização — Fase 6 (continuação)

Uma rodada de **code review externo** (10 pontos levantados, 6
confirmados e corrigidos, 2 já resolvidos em rodada anterior, 1 falso
alarme, 1 imprecisão factual corrigida) foi tratada como parte
contínua da Fase 6 — reforça a prática de auditar criticamente
qualquer sugestão (própria ou externa) antes de aplicar, em vez de
aceitar ou rejeitar por autoridade da fonte. Ver seção 9 das
"Decisões de Arquitetura" no README para o detalhamento completo.
PROCESSOEOF
echo "Nota adicionada ao PROCESSO_DESENVOLVIMENTO.md."
else
  echo "Nota ja existe no processo, pulando."
fi

echo
echo "============================================================"
echo "Documentacao corrigida. Revise antes de comitar:"
echo "  grep -A5 'BP5' docs/TUTORIAL_ARQUITETURA_DEBUG.md | head -20"
echo
echo "Commit:"
echo "  uv run pre-commit run --all-files"
echo "  git add README.md docs/"
echo "  git commit -m 'docs: sincroniza documentacao com fixes do code review'"
echo "  git push"
echo "============================================================"
