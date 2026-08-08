"""Ingestao de documentos no Qdrant, com duas fontes/collections
separadas (incidents / reference).

Processa arquivo por arquivo (baixo uso de memoria) e mantem um
arquivo de estado por target, para poder interromper e retomar sem
reprocessar o que ja foi indexado.

Uso:
    uv run python -m app.rag.ingest --target incidents
    uv run python -m app.rag.ingest --target reference
    uv run python -m app.rag.ingest --target reference --limit 5
    uv run python -m app.rag.ingest --target reference --exclude "PDF Sessions" --exclude "_Downloaded Books"
    uv run python -m app.rag.ingest --target reference --reset   # ignora estado e reprocessa tudo
"""
import argparse
import json
from pathlib import Path
from uuid import uuid4

from langchain_text_splitters import MarkdownTextSplitter
from langchain_community.document_loaders import PyPDFLoader
from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

BASE_DIR = Path(__file__).resolve().parents[2]
from app.config import settings

EMBEDDING_MODEL = settings.embedding_model
QDRANT_URL = settings.qdrant_url
EMBED_BATCH_SIZE = 16  # chunks embedados/gravados por vez, por arquivo

TARGETS = {
    "incidents": {
        "collection": "sap_incident_docs",
        "primary_dir": BASE_DIR / "data" / "knowledge_base",
        "fallback_dir": BASE_DIR / "data" / "sample_docs",
        "chunk_size": 500,
        "chunk_overlap": 50,
        "state_file": BASE_DIR / "data" / ".ingest_state_incidents.json",
    },
    "reference": {
        "collection": "sap_reference_library",
        "primary_dir": BASE_DIR / "data" / "reference_library",
        "fallback_dir": None,
        "chunk_size": 1000,
        "chunk_overlap": 150,
        "state_file": BASE_DIR / "data" / ".ingest_state_reference.json",
    },
}


def resolve_source_dir(cfg: dict) -> Path:
    primary = cfg["primary_dir"]
    if primary.exists() and any(primary.rglob("*")):
        return primary
    if cfg["fallback_dir"] is not None:
        print(f"[aviso] {primary} vazia, usando fallback {cfg['fallback_dir']}")
        return cfg["fallback_dir"]
    return primary


def find_files(source_dir: Path, excludes: list[str]) -> list[Path]:
    files = list(source_dir.rglob("*.md")) + list(source_dir.rglob("*.pdf"))
    if excludes:
        files = [f for f in files if not any(ex.lower() in str(f).lower() for ex in excludes)]
    return sorted(files)


def load_state(state_file: Path) -> set[str]:
    if state_file.exists():
        return set(json.loads(state_file.read_text(encoding="utf-8")))
    return set()


def save_state(state_file: Path, processed: set[str]) -> None:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(sorted(processed), ensure_ascii=False, indent=2), encoding="utf-8")


def extract_text(path: Path) -> str:
    if path.suffix.lower() == ".pdf":
        pages = PyPDFLoader(str(path)).load()
        return "\n\n".join(p.page_content for p in pages)
    return path.read_text(encoding="utf-8", errors="ignore")


def ensure_collection(client: QdrantClient, collection_name: str, vector_size: int) -> None:
    existing = [c.name for c in client.get_collections().collections]
    if collection_name not in existing:
        client.create_collection(
            collection_name=collection_name,
            vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE),
        )
        print(f"Collection '{collection_name}' criada.")


def embed_and_upsert(client, collection, embeddings, chunks: list[str], source: str) -> None:
    for i in range(0, len(chunks), EMBED_BATCH_SIZE):
        batch = chunks[i : i + EMBED_BATCH_SIZE]
        vectors = embeddings.embed_documents(batch)
        ensure_collection(client, collection, len(vectors[0]))
        points = [
            PointStruct(id=str(uuid4()), vector=v, payload={"source": source, "text": t})
            for v, t in zip(vectors, batch)
        ]
        client.upsert(collection_name=collection, points=points)


def run_ingest(target: str, limit: int | None, excludes: list[str], reset: bool) -> None:
    cfg = TARGETS[target]
    source_dir = resolve_source_dir(cfg)
    print(f"[{target}] Fonte: {source_dir}")

    all_files = find_files(source_dir, excludes)
    print(f"[{target}] {len(all_files)} arquivo(s) encontrados (.md + .pdf, recursivo)")

    processed = set() if reset else load_state(cfg["state_file"])
    pending = [f for f in all_files if str(f) not in processed]
    print(f"[{target}] {len(processed)} ja processados anteriormente, {len(pending)} pendentes")

    if limit:
        pending = pending[:limit]
        print(f"[{target}] --limit aplicado: processando {len(pending)} arquivo(s) nesta execucao")

    if not pending:
        print(f"[{target}] Nada a fazer.")
        return

    embeddings = OllamaEmbeddings(model=EMBEDDING_MODEL)
    splitter = MarkdownTextSplitter(chunk_size=cfg["chunk_size"], chunk_overlap=cfg["chunk_overlap"])
    client = QdrantClient(url=QDRANT_URL)

    for idx, path in enumerate(pending, start=1):
        rel = path.relative_to(source_dir)
        print(f"[{target}] ({idx}/{len(pending)}) processando: {rel}")
        try:
            text = extract_text(path)
            chunks = splitter.split_text(text)
            if not chunks:
                print(f"    [aviso] nenhum texto extraido, pulando")
            else:
                embed_and_upsert(client, cfg["collection"], embeddings, chunks, str(rel))
                print(f"    {len(chunks)} chunk(s) indexados")
        except Exception as exc:  # noqa: BLE001
            print(f"    [ERRO] falhou em {rel}: {exc} -- pulando este arquivo")
            continue

        processed.add(str(path))
        save_state(cfg["state_file"], processed)  # salva progresso a cada arquivo

    print(f"[{target}] Concluido. Total processado ate agora: {len(processed)} arquivo(s).")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=["incidents", "reference", "all"], default="incidents")
    parser.add_argument("--limit", type=int, default=None, help="Processar so os N primeiros arquivos pendentes (teste)")
    parser.add_argument("--exclude", action="append", default=[], help="Substring de caminho a excluir (pode repetir)")
    parser.add_argument("--reset", action="store_true", help="Ignora estado salvo e reprocessa tudo")
    args = parser.parse_args()

    targets = ["incidents", "reference"] if args.target == "all" else [args.target]
    for t in targets:
        run_ingest(t, args.limit, args.exclude, args.reset)


if __name__ == "__main__":
    main()
