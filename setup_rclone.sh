#!/usr/bin/env bash
# ============================================================
# Atualiza app/rag/ingest.py para:
#  - ler de data/knowledge_base (sincronizada via rclone/Drive)
#    alem de data/sample_docs (fallback)
#  - suportar PDF alem de Markdown
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash update_ingest_for_knowledge_base.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/2 - Adicionando dependencia pypdf ==="
uv add pypdf

echo "=== 2/2 - Reescrevendo app/rag/ingest.py ==="
cat > app/rag/ingest.py << 'INGESTEOF'
"""Ingestao dos documentos de conhecimento no Qdrant.

Le arquivos .md e .pdf de duas fontes possiveis:
  - data/knowledge_base/  (sincronizada do Google Drive via rclone)
  - data/sample_docs/     (documentos de exemplo, usados como fallback
                            se knowledge_base estiver vazia)

Divide em chunks, gera embeddings via Ollama e indexa no Qdrant.

Uso:
    uv run python -m app.rag.ingest
    uv run python -m app.rag.ingest --source data/knowledge_base
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
KNOWLEDGE_BASE_DIR = BASE_DIR / "data" / "knowledge_base"
SAMPLE_DOCS_DIR = BASE_DIR / "data" / "sample_docs"
COLLECTION_NAME = "sap_incident_docs"
EMBEDDING_MODEL = "nomic-embed-text"
QDRANT_URL = "http://127.0.0.1:6333"


def resolve_source_dir() -> Path:
    """Usa knowledge_base se tiver conteudo, senao cai para sample_docs."""
    if KNOWLEDGE_BASE_DIR.exists() and any(KNOWLEDGE_BASE_DIR.iterdir()):
        return KNOWLEDGE_BASE_DIR
    print(f"[aviso] {KNOWLEDGE_BASE_DIR} vazia ou inexistente, usando {SAMPLE_DOCS_DIR}")
    return SAMPLE_DOCS_DIR


def load_documents(source_dir: Path) -> list[dict]:
    docs = []

    for path in sorted(source_dir.glob("*.md")):
        docs.append({"source": path.name, "text": path.read_text(encoding="utf-8")})

    for path in sorted(source_dir.glob("*.pdf")):
        pages = PyPDFLoader(str(path)).load()
        full_text = "\n\n".join(p.page_content for p in pages)
        docs.append({"source": path.name, "text": full_text})

    return docs


def chunk_documents(docs: list[dict]) -> list[dict]:
    splitter = MarkdownTextSplitter(chunk_size=800, chunk_overlap=100)
    chunks = []
    for doc in docs:
        for piece in splitter.split_text(doc["text"]):
            chunks.append({"source": doc["source"], "text": piece})
    return chunks


def ensure_collection(client: QdrantClient, vector_size: int) -> None:
    existing = [c.name for c in client.get_collections().collections]
    if COLLECTION_NAME not in existing:
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        print(f"Collection '{COLLECTION_NAME}' criada.")
    else:
        print(f"Collection '{COLLECTION_NAME}' ja existe, reutilizando.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=None,
        help="Pasta com os documentos (.md/.pdf). Padrao: auto-detecta knowledge_base ou sample_docs.",
    )
    args = parser.parse_args()

    source_dir = args.source or resolve_source_dir()
    print(f"Lendo documentos de: {source_dir}")

    docs = load_documents(source_dir)
    print(f"{len(docs)} documento(s) encontrados (.md + .pdf)")

    if not docs:
        print("Nenhum documento encontrado. Nada a indexar.")
        return

    chunks = chunk_documents(docs)
    print(f"{len(chunks)} chunk(s) gerados apos split")

    embeddings = OllamaEmbeddings(model=EMBEDDING_MODEL)
    vectors = embeddings.embed_documents([c["text"] for c in chunks])
    vector_size = len(vectors[0])

    client = QdrantClient(url=QDRANT_URL)
    ensure_collection(client, vector_size)

    points = [
        PointStruct(
            id=str(uuid4()),
            vector=vector,
            payload={"source": chunk["source"], "text": chunk["text"]},
        )
        for chunk, vector in zip(chunks, vectors)
    ]
    client.upsert(collection_name=COLLECTION_NAME, points=points)
    print(f"{len(points)} chunk(s) indexados na collection '{COLLECTION_NAME}'.")


if __name__ == "__main__":
    main()
INGESTEOF

echo
echo "============================================================"
echo "ingest.py atualizado. Agora ele:"
echo "  - le .md E .pdf"
echo "  - usa data/knowledge_base automaticamente se ela tiver arquivos"
echo "    (senao cai de volta para data/sample_docs)"
echo
echo "Depois de sincronizar via rclone, rode:"
echo "  cd ~/sap-integration-copilot"
echo "  uv run python -m app.rag.ingest"
echo "============================================================"
