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

from app.agent import graph as graph_module
from app.models import IncidentRequest


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
