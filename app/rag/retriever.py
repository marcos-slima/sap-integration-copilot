"""Consulta (retrieval) nas bases de conhecimento indexadas no Qdrant.

Correcoes aplicadas apos code review:
  - QdrantClient e OllamaEmbeddings sao singletons (via lru_cache),
    nao recriados a cada chamada de retrieve() - evita descartar
    reuso de conexao HTTP a cada request
  - score_threshold filtra resultados de baixa relevancia na propria
    query ao Qdrant (nao em Python depois) - sem isso, top_k sempre
    retornava 3 resultados mesmo quando nenhum era realmente relevante,
    e o LLM tentava construir uma causa raiz em cima de contexto fraco

Duas collections independentes:
  sap_incident_docs      -> usada pelo fluxo de diagnostico do Copilot
  sap_reference_library  -> usada so para estudo/consulta pessoal
"""

from functools import lru_cache

from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient

from app.config import settings

EMBEDDING_MODEL = settings.embedding_model
QDRANT_URL = settings.qdrant_url

# Valor inicial conservador - abaixo de todos os scores de match
# correto observados ate hoje (0.55-0.90), mas acima do que se espera
# de ruido puro. Deve ser recalibrado com mais dado real ao longo do
# tempo, nao e um numero definitivo.
DEFAULT_SCORE_THRESHOLD = 0.5

COLLECTIONS = {
    "incidents": "sap_incident_docs",
    "reference": "sap_reference_library",
}


@lru_cache(maxsize=1)
def _get_qdrant_client() -> QdrantClient:
    return QdrantClient(url=QDRANT_URL)


@lru_cache(maxsize=1)
def _get_embeddings() -> OllamaEmbeddings:
    return OllamaEmbeddings(model=EMBEDDING_MODEL)


def retrieve(
    query: str,
    target: str = "incidents",
    top_k: int = 3,
    score_threshold: float = DEFAULT_SCORE_THRESHOLD,
) -> list[dict]:
    """Retorna ate top_k chunks mais relevantes para a query, na
    collection correspondente a `target`, descartando resultados
    abaixo de score_threshold. Pode retornar lista vazia se nada
    passar do limiar - isso e intencional, nao um bug.
    """
    collection_name = COLLECTIONS[target]

    embeddings = _get_embeddings()
    query_vector = embeddings.embed_query(query)

    client = _get_qdrant_client()
    results = client.query_points(
        collection_name=collection_name,
        query=query_vector,
        limit=top_k,
        score_threshold=score_threshold,
    ).points

    return [
        {
            "source": hit.payload.get("source"),
            "text": hit.payload.get("text"),
            "score": hit.score,
        }
        for hit in results
    ]


if __name__ == "__main__":
    import sys

    target = "incidents"
    args = sys.argv[1:]
    if args and args[0] in ("incidents", "reference"):
        target = args[0]
        args = args[1:]

    query = " ".join(args) or "iFlow falhando com timeout"
    print(f"[{target}] Query: {query}\n")
    hits = retrieve(query, target=target)
    if not hits:
        print(f"(nenhum resultado acima do score_threshold={DEFAULT_SCORE_THRESHOLD})")
    for i, hit in enumerate(hits, start=1):
        print(f"--- resultado {i} (score={hit['score']:.4f}, fonte={hit['source']}) ---")
        print(hit["text"][:300])
        print()
