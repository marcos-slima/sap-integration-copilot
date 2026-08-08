"""Configuracao compartilhada dos testes.

Testes marcados com @pytest.mark.integration sao pulados
automaticamente (nao falham) se a stack local (Qdrant e/ou Ollama)
nao estiver acessivel - isso evita falsos negativos em uma maquina
sem o ambiente de IA local rodando, e evita que o CI quebre por falta
de infraestrutura que so existe localmente.
"""
import socket

import pytest


def _port_open(host: str, port: int, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _stack_available() -> bool:
    qdrant_up = _port_open("127.0.0.1", 6333)
    ollama_up = _port_open("127.0.0.1", 11434)
    return qdrant_up and ollama_up


def pytest_collection_modifyitems(config, items):
    if _stack_available():
        return
    skip_marker = pytest.mark.skip(
        reason="Stack local (Qdrant/Ollama) indisponivel em 127.0.0.1 - "
        "rode 'docker compose up -d' em ~/ai-stack e confirme o Ollama ativo"
    )
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip_marker)
