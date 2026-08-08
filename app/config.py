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
