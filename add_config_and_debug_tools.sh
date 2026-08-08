#!/usr/bin/env bash
# ============================================================
# Cria app/config.py (config centralizada, lida do .env) e
# configuracoes de debug do VS Code, para o usuario poder
# inspecionar/depurar o sistema sem depender de mim.
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_config_and_debug_tools.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/5 - Adicionando pydantic-settings e debugpy ==="
uv add pydantic-settings
uv add --dev debugpy

echo "=== 2/5 - Criando app/config.py ==="
cat > app/config.py << 'CONFIGEOF'
"""Configuracao centralizada do SAP Integration Copilot.

Toda configuracao (URLs, modelos, credenciais) vem daqui - nunca
hardcoded espalhado pelo codigo. Le do .env automaticamente.

Para VER exatamente o que esta configurado agora (sem precisar ler
codigo Python), rode:

    uv run python -m app.config

Isso imprime a configuracao efetiva (valores do .env + defaults),
mascarando senhas/chaves - util pra depurar "por que esta apontando
pro lugar errado" sem depender de mais ninguem.
"""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Ollama
    ollama_host: str = "http://127.0.0.1:11434"
    llm_model: str = "qwen2.5-coder:32b"
    embedding_model: str = "nomic-embed-text"

    # Qdrant
    qdrant_url: str = "http://127.0.0.1:6333"

    # Neo4j
    neo4j_uri: str = "bolt://127.0.0.1:7687"
    neo4j_user: str = "neo4j"
    neo4j_password: str = ""

    # Langfuse
    langfuse_host: str = "http://127.0.0.1:3000"
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",  # nao quebra se o .env tiver variaveis extras
    )


settings = Settings()


def _mask(value: str) -> str:
    if not value:
        return "(vazio)"
    if len(value) <= 6:
        return "*" * len(value)
    return f"{value[:3]}...{value[-3:]}"


_SENSITIVE_KEYWORDS = ("password", "secret", "key")


def _print_effective_config() -> None:
    print("Configuracao efetiva (env_file=.env + defaults do codigo):\n")
    for field_name in settings.__class__.model_fields:
        value = str(getattr(settings, field_name))
        is_sensitive = any(kw in field_name for kw in _SENSITIVE_KEYWORDS)
        display = _mask(value) if is_sensitive else (value or "(vazio)")
        print(f"  {field_name:22} = {display}")
    print(
        "\nSe algum valor nao bater com o esperado, confira o arquivo "
        "'.env' na raiz do projeto - essa e a unica fonte que este "
        "comando le, alem dos defaults acima."
    )


if __name__ == "__main__":
    _print_effective_config()
CONFIGEOF

echo "=== 3/5 - Atualizando modulos para usar app.config em vez de constantes soltas ==="

# ingest.py: substitui as constantes hardcoded pelas de settings
python3 - << 'PYEOF'
import re
from pathlib import Path

path = Path("app/rag/ingest.py")
text = path.read_text(encoding="utf-8")

text = text.replace(
    'EMBEDDING_MODEL = "nomic-embed-text"\nQDRANT_URL = "http://127.0.0.1:6333"',
    'from app.config import settings\n\nEMBEDDING_MODEL = settings.embedding_model\nQDRANT_URL = settings.qdrant_url',
)
path.write_text(text, encoding="utf-8")
print("app/rag/ingest.py atualizado.")
PYEOF

# retriever.py: idem
python3 - << 'PYEOF'
from pathlib import Path

path = Path("app/rag/retriever.py")
text = path.read_text(encoding="utf-8")

text = text.replace(
    'EMBEDDING_MODEL = "nomic-embed-text"\nQDRANT_URL = "http://127.0.0.1:6333"',
    'from app.config import settings\n\nEMBEDDING_MODEL = settings.embedding_model\nQDRANT_URL = settings.qdrant_url',
)
path.write_text(text, encoding="utf-8")
print("app/rag/retriever.py atualizado.")
PYEOF

# graph.py: LLM_MODEL passa a vir de settings (continua sendo um
# atributo de modulo sobrescrevivel, o promptfoo_provider.py que
# monkeypatcha graph_module.LLM_MODEL continua funcionando igual)
python3 - << 'PYEOF'
from pathlib import Path

path = Path("app/agent/graph.py")
text = path.read_text(encoding="utf-8")

text = text.replace(
    'LLM_MODEL = "qwen2.5-coder:32b"',
    'from app.config import settings\n\nLLM_MODEL = settings.llm_model',
)
path.write_text(text, encoding="utf-8")
print("app/agent/graph.py atualizado.")
PYEOF

echo "=== 4/5 - Criando .vscode/launch.json (debugger visual) ==="
mkdir -p .vscode
cat > .vscode/launch.json << 'LAUNCHEOF'
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Debug: graph.py (caso IDoc travado)",
      "type": "debugpy",
      "request": "launch",
      "module": "app.agent.graph",
      "args": ["IDoc travado", "--interface", "rfc", "--id", "RFC-IDOC-51-DEMO", "--debug"],
      "console": "integratedTerminal",
      "justMyCode": true
    },
    {
      "name": "Debug: graph.py (texto livre)",
      "type": "debugpy",
      "request": "launch",
      "module": "app.agent.graph",
      "args": ["${input:incidentDescription}", "--debug"],
      "console": "integratedTerminal",
      "justMyCode": true
    },
    {
      "name": "Debug: pytest (tudo)",
      "type": "debugpy",
      "request": "launch",
      "module": "pytest",
      "args": ["-v"],
      "console": "integratedTerminal",
      "justMyCode": true
    },
    {
      "name": "Debug: pytest (so unitarios, rapido)",
      "type": "debugpy",
      "request": "launch",
      "module": "pytest",
      "args": ["tests/test_connectors.py", "-v"],
      "console": "integratedTerminal",
      "justMyCode": true
    },
    {
      "name": "Debug: FastAPI (uvicorn)",
      "type": "debugpy",
      "request": "launch",
      "module": "uvicorn",
      "args": ["app.main:app", "--reload"],
      "console": "integratedTerminal",
      "justMyCode": true
    },
    {
      "name": "Ver configuracao efetiva (app.config)",
      "type": "debugpy",
      "request": "launch",
      "module": "app.config",
      "console": "integratedTerminal",
      "justMyCode": true
    }
  ],
  "inputs": [
    {
      "id": "incidentDescription",
      "type": "promptString",
      "description": "Descricao do incidente para debugar"
    }
  ]
}
LAUNCHEOF

echo "=== 5/5 - Sync das dependencias ==="
uv sync

echo
echo "============================================================"
echo "app/config.py criado. Para VER a configuracao efetiva a"
echo "qualquer momento, sem precisar de mim:"
echo
echo "  uv run python -m app.config"
echo
echo "Para DEPURAR visualmente no VS Code:"
echo "  1. Abra a pasta ~/sap-integration-copilot no VS Code"
echo "  2. Va na aba 'Run and Debug' (icone de play com bug, barra lateral)"
echo "  3. Escolha uma das opcoes no menu (ex: 'Debug: graph.py"
echo "     (caso IDoc travado)')"
echo "  4. Clique em botoes na margem esquerda do codigo para"
echo "     colocar breakpoints, depois aperte o play verde (F5)"
echo "  5. O codigo para exatamente naquela linha - voce pode"
echo "     inspecionar variaveis, avancar linha a linha (F10), etc."
echo
echo "Rode a suite pytest de novo para confirmar que a refatoracao"
echo "para app.config nao quebrou nada:"
echo "  uv run pytest -v"
echo "============================================================"
