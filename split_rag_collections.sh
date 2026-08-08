#!/usr/bin/env bash
# ============================================================
# Separa o RAG em duas collections:
#   sap_incident_docs      <- data/knowledge_base (+ sample_docs fallback)
#                              usado pelo Copilot de diagnostico
#   sap_reference_library  <- data/reference_library (livros SAP)
#                              usado como base de estudo/consulta,
#                              NAO entra no fluxo de diagnostico
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash split_rag_collections.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/3 - Criando pasta para a biblioteca de referencia ==="
mkdir -p data/reference_library

echo "=== 2/3 - Reescrevendo app/rag/ingest.py (multi-collection) ==="
cat > app/rag/ingest.py << 'INGESTEOF'
"""Ingestao de documentos no Qdrant, com duas fontes/collections
separadas:

  sap_incident_docs      -> data/knowledge_base/ (fallback: data/sample_docs/)
                             material curado de troubleshooting, usado
                             pelo fluxo de diagnostico do Copilot.

  sap_reference_library   -> data/reference_library/ (livros/manuais SAP)
                             base de estudo/consulta, NAO usada no
                             fluxo de diagnostico de incidentes.

Uso:
    uv run python -m app.rag.ingest --target incidents
    uv run python -m app.rag.ingest --target reference
"""
import argparse
from pathlib import Path
from uuid import uuid4

from langchain_text_splitters import MarkdownTextSplitter
from langchain_community.document_loaders import PyPDFLoader
from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

BASE_DIR = Path(__file__).resolve().parents[2]
EMBEDDING_MODEL = "nomic-embed-text"
QDRANT_URL = "http://127.0.0.1:6333"

TARGETS = {
    "incidents": {
        "collection": "sap_incident_docs",
        "primary_dir": BASE_DIR / "data" / "knowledge_base",
        "fallback_dir": BASE_DIR / "data" / "sample_docs",
        "chunk_size": 500,
        "chunk_overlap": 50,
    },
    "reference": {
        "collection": "sap_reference_library",
        "primary_dir": BASE_DIR / "data" / "reference_library",
        "fallback_dir": None,
        "chunk_size": 1000,
        "chunk_overlap": 150,
    },
}


def resolve_source_dir(cfg: dict) -> Path:
    primary = cfg["primary_dir"]
    if primary.exists() and any(primary.iterdir()):
        return primary
    if cfg["fallback_dir"] is not None:
        print(f"[aviso] {primary} vazia, usando fallback {cfg['fallback_dir']}")
        return cfg["fallback_dir"]
    return primary


def load_documents(source_dir: Path) -> list[dict]:
    docs = []
    for path in sorted(source_dir.glob("*.md")):
        docs.append({"source": path.name, "text": path.read_text(encoding="utf-8")})
    for path in sorted(source_dir.glob("*.pdf")):
        pages = PyPDFLoader(str(path)).load()
        full_text = "\n\n".join(p.page_content for p in pages)
        docs.append({"source": path.name, "text": full_text})
    return docs


def chunk_documents(docs: list[dict], chunk_size: int, chunk_overlap: int) -> list[dict]:
    splitter = MarkdownTextSplitter(chunk_size=chunk_size, chunk_overlap=chunk_overlap)
    chunks = []
    for doc in docs:
        for piece in splitter.split_text(doc["text"]):
            chunks.append({"source": doc["source"], "text": piece})
    return chunks


def ensure_collection(client: QdrantClient, collection_name: str, vector_size: int) -> None:
    existing = [c.name for c in client.get_collections().collections]
    if collection_name not in existing:
        client.create_collection(
            collection_name=collection_name,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        print(f"Collection '{collection_name}' criada.")
    else:
        print(f"Collection '{collection_name}' ja existe, reutilizando.")


def run_ingest(target: str) -> None:
    cfg = TARGETS[target]
    source_dir = resolve_source_dir(cfg)
    print(f"[{target}] Lendo documentos de: {source_dir}")

    docs = load_documents(source_dir)
    print(f"[{target}] {len(docs)} documento(s) encontrados (.md + .pdf)")
    if not docs:
        print(f"[{target}] Nenhum documento encontrado. Nada a indexar.")
        return

    chunks = chunk_documents(docs, cfg["chunk_size"], cfg["chunk_overlap"])
    print(f"[{target}] {len(chunks)} chunk(s) gerados apos split")

    embeddings = OllamaEmbeddings(model=EMBEDDING_MODEL)
    vectors = embeddings.embed_documents([c["text"] for c in chunks])
    vector_size = len(vectors[0])

    client = QdrantClient(url=QDRANT_URL)
    ensure_collection(client, cfg["collection"], vector_size)

    points = [
        PointStruct(
            id=str(uuid4()),
            vector=vector,
            payload={"source": chunk["source"], "text": chunk["text"]},
        )
        for chunk, vector in zip(chunks, vectors)
    ]
    client.upsert(collection_name=cfg["collection"], points=points)
    print(f"[{target}] {len(points)} chunk(s) indexados em '{cfg['collection']}'.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--target",
        choices=["incidents", "reference", "all"],
        default="incidents",
        help="Qual base indexar. Padrao: incidents.",
    )
    args = parser.parse_args()

    targets = ["incidents", "reference"] if args.target == "all" else [args.target]
    for t in targets:
        run_ingest(t)


if __name__ == "__main__":
    main()
INGESTEOF

echo "=== 3/3 - Reescrevendo app/rag/retriever.py (multi-collection) ==="
cat > app/rag/retriever.py << 'RETRIEVEREOF'
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
RETRIEVEREOF

echo
echo "============================================================"
echo "RAG separado em duas collections."
echo
echo "Sincronize os livros SAP para a pasta certa (reference, nao knowledge_base):"
echo "  rclone sync gdrive:\"Books/SAP Books\" ~/sap-integration-copilot/data/reference_library --progress"
echo
echo "Indexar so os incidentes (o que o Copilot usa):"
echo "  uv run python -m app.rag.ingest --target incidents"
echo
echo "Indexar so a biblioteca de referencia (livros):"
echo "  uv run python -m app.rag.ingest --target reference"
echo
echo "Consultar uma base especifica:"
echo "  uv run python -m app.rag.retriever incidents \"erro 401\""
echo "  uv run python -m app.rag.retriever reference \"arquitetura RFC\""
echo "============================================================"
