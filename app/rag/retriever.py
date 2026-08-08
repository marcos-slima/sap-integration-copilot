"""Consulta (retrieval) nas bases de conhecimento indexadas no Qdrant.

Duas collections independentes:
  sap_incident_docs      -> usada pelo fluxo de diagnostico do Copilot
  sap_reference_library  -> usada so para estudo/consulta pessoal
"""
from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient

EMBEDDING_MODEL = "nomic-embed-text"
QDRANT_URL = "http://127.0.0.1:6333"

COLLECTIONS = {
    "incidents": "sap_incident_docs",
    "reference": "sap_reference_library",
}


def retrieve(query: str, target: str = "incidents", top_k: int = 3) -> list[dict]:
    """Retorna os top_k chunks mais relevantes para a query, na
    collection correspondente a `target` ('incidents' ou 'reference').
    """
    collection_name = COLLECTIONS[target]

    embeddings = OllamaEmbeddings(model=EMBEDDING_MODEL)
    query_vector = embeddings.embed_query(query)

    client = QdrantClient(url=QDRANT_URL)
    results = client.query_points(
        collection_name=collection_name,
        query=query_vector,
        limit=top_k,
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
    for i, hit in enumerate(retrieve(query, target=target), start=1):
        print(f"--- resultado {i} (score={hit['score']:.4f}, fonte={hit['source']}) ---")
        print(hit["text"][:300])
        print()
