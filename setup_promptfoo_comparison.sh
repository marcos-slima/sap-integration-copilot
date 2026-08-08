#!/usr/bin/env bash
# ============================================================
# Instala Node.js (dependencia do promptfoo) e monta uma
# comparacao formal entre qwen3:30b-a3b e qwen2.5-coder:32b,
# rodando o PIPELINE REAL do Copilot (run_diagnosis), nao so o
# LLM isolado - inclui conector, retriever e guardrails.
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash setup_promptfoo_comparison.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/4 - Instalando Node.js/npm (dependencia do promptfoo), se faltar ==="
if ! command -v npx &>/dev/null; then
  sudo apt-get install -y nodejs npm
else
  echo "npx ja disponivel: $(npx --version)"
fi

echo "=== 2/4 - Criando provider Python (roda o pipeline real do Copilot) ==="
mkdir -p scripts
cat > scripts/promptfoo_provider.py << 'PROVIDEREOF'
#!/usr/bin/env python3
"""Provider customizado do promptfoo.

Recebe o modelo a usar (primeiro argv, definido no promptfooconfig.yaml)
e o "prompt" renderizado (segundo argv) no formato:
    descricao|||interface_type|||identifier
(onde interface_type/identifier podem ser a string "none")

Roda o pipeline REAL do Copilot (run_diagnosis) - conector, RAG,
guardrails - trocando so o modelo do LLM. Imprime um JSON compacto
com o resultado, para o promptfoo avaliar via asserts.

IMPORTANTE: nao imprimir nada alem do JSON final no stdout.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.agent import graph as graph_module  # noqa: E402
from app.models import IncidentRequest  # noqa: E402


def main() -> None:
    model = sys.argv[1]
    raw_prompt = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()

    parts = raw_prompt.strip().split("|||")
    description = parts[0] if len(parts) > 0 else ""
    interface_type = parts[1] if len(parts) > 1 and parts[1] != "none" else None
    identifier = parts[2] if len(parts) > 2 and parts[2] != "none" else None

    # Troca o modelo usado pelo grafo, sem tocar no resto do pipeline
    graph_module.LLM_MODEL = model

    request = IncidentRequest(
        description=description,
        interface_type=interface_type,
        identifier=identifier,
    )
    result = graph_module.run_diagnosis(request)

    print(
        json.dumps(
            {
                "matched_source": result.matched_source,
                "confidence": result.confidence,
                "probable_root_cause": result.probable_root_cause,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
PROVIDEREOF

echo "=== 3/4 - Criando prompts/case.txt e promptfooconfig.yaml ==="
mkdir -p prompts
cat > prompts/case.txt << 'PROMPTEOF'
{{description}}|||{{interface_type}}|||{{identifier}}
PROMPTEOF

cat > promptfooconfig.yaml << 'CONFIGEOF'
description: "Comparacao qwen3:30b-a3b vs qwen2.5-coder:32b no diagnostico do SAP Integration Copilot (pipeline real: conector + RAG + guardrails)"

prompts:
  - file://prompts/case.txt

providers:
  - id: "exec:uv run python3 scripts/promptfoo_provider.py qwen3:30b-a3b"
    label: "qwen3:30b-a3b (atual)"
  - id: "exec:uv run python3 scripts/promptfoo_provider.py qwen2.5-coder:32b"
    label: "qwen2.5-coder:32b (candidato)"

tests:
  - description: "401 sem conector"
    vars: { description: "iFlow falhando com erro 401", interface_type: "none", identifier: "none" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'cpi_http_401.md'"

  - description: "401 com conector OData"
    vars: { description: "investigar falha reportada no iFlow", interface_type: "odata", identifier: "CPI-401-DEMO" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'cpi_http_401.md' && JSON.parse(output).confidence >= 0.6"

  - description: "IDoc 51 com conector RFC (caso que ja quebrou 2x manualmente)"
    vars: { description: "IDoc travado", interface_type: "rfc", identifier: "RFC-IDOC-51-DEMO" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'idoc_status_51.md' && JSON.parse(output).confidence >= 0.6"

  - description: "IDoc 51 com conector RFC - repeticao 2 (teste de estabilidade)"
    vars: { description: "IDoc travado", interface_type: "rfc", identifier: "RFC-IDOC-51-DEMO" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'idoc_status_51.md' && JSON.parse(output).confidence >= 0.6"

  - description: "IDoc 51 com conector RFC - repeticao 3 (teste de estabilidade)"
    vars: { description: "IDoc travado", interface_type: "rfc", identifier: "RFC-IDOC-51-DEMO" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'idoc_status_51.md' && JSON.parse(output).confidence >= 0.6"

  - description: "RFC connection refused com conector"
    vars: { description: "SM59 não conecta", interface_type: "rfc", identifier: "RFC-CONN-REFUSED-DEMO" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'rfc_connection_refused.md' && JSON.parse(output).confidence >= 0.6"

  - description: "OData timeout sem conector"
    vars: { description: "iFlow travando ao consumir OData sem retorno", interface_type: "none", identifier: "none" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'odata_timeout_cpi.md'"

  - description: "IDoc 51 sem conector"
    vars: { description: "IDoc parado com status 51", interface_type: "none", identifier: "none" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'idoc_status_51.md'"

  - description: "RFC connection refused sem conector"
    vars: { description: "SM59 dando erro de conexão recusada", interface_type: "none", identifier: "none" }
    assert:
      - type: javascript
        value: "JSON.parse(output).matched_source === 'rfc_connection_refused.md'"

  - description: "Identificador desconhecido - guardrail de seguranca (nao deve ter alta confianca)"
    vars: { description: "algo estranho aconteceu", interface_type: "odata", identifier: "XPTO-999-NAO-EXISTE" }
    assert:
      - type: javascript
        value: "JSON.parse(output).confidence < 0.6"
CONFIGEOF

echo "=== 4/4 - Ajustando .gitignore para artefatos do promptfoo ==="
cat >> .gitignore << 'GITIGNOREEOF'
.promptfoo/
promptfoo-output*
GITIGNOREEOF

echo
echo "============================================================"
echo "Setup do promptfoo concluido."
echo
echo "IMPORTANTE - RAM limitada (~30GB): rode com concorrencia 1,"
echo "para nao tentar carregar dois modelos grandes ao mesmo tempo:"
echo
echo "  cd ~/sap-integration-copilot"
echo "  npx promptfoo eval --max-concurrency 1"
echo
echo "Sao 10 casos x 2 modelos = 20 chamadas reais ao pipeline"
echo "completo (conector+RAG+LLM) - pode levar varios minutos."
echo
echo "Depois, ver o resultado num dashboard interativo no navegador:"
echo "  npx promptfoo view"
echo "============================================================"
