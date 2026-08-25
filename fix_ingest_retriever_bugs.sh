#!/usr/bin/env bash
# ============================================================
# Corrige 2 bugs de producao encontrados em code review:
#  1. ingest.py: ensure_collection() dentro do loop de batch
#     (deveria rodar 1x por execucao, nao 1x por batch/arquivo);
#     --reset nao deletava pontos antigos antes de reindexar,
#     causando duplicata permanente (uuid4() sempre novo)
#  2. retriever.py: QdrantClient/OllamaEmbeddings recriados a
#     cada chamada (sem reuso de conexao); sem score_threshold,
#     retornando resultados de baixa relevancia sem filtro
#
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash fix_ingest_retriever_bugs.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/3 - Reescrevendo app/rag/ingest.py (fix duplo) ==="
cat > app/rag/ingest.py << 'INGESTEOF'
"""Ingestao de documentos no Qdrant, com duas fontes/collections
separadas (incidents / reference).

Processa arquivo por arquivo (baixo uso de memoria) e mantem um
arquivo de estado por target, para poder interromper e retomar sem
reprocessar o que ja foi indexado.

Correcoes aplicadas apos code review:
  - ensure_collection() roda 1x por execucao (nao 1x por batch)
  - antes de (re)indexar um arquivo, os pontos antigos daquele
    'source' sao deletados primeiro - evita duplicata permanente
    em reprocessamentos (--reset, ou reruns apos falha parcial)

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

from langchain_community.document_loaders import PyPDFLoader
from langchain_ollama import OllamaEmbeddings
from langchain_text_splitters import MarkdownTextSplitter
from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    MatchValue,
    PointStruct,
    VectorParams,
)

from app.config import settings

BASE_DIR = Path(__file__).resolve().parents[2]
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


def probe_vector_size(embeddings: OllamaEmbeddings) -> int:
    """Faz um embedding minimo so pra descobrir a dimensao do vetor,
    sem depender de ja ter chunks reais prontos."""
    return len(embeddings.embed_query("probe"))


def delete_existing_points_for_source(client: QdrantClient, collection: str, source: str) -> None:
    """Remove pontos antigos desse arquivo antes de reindexar - sem
    isso, reprocessar o mesmo arquivo (--reset ou rerun) acumula
    duplicata permanente, ja que cada ponto usa um uuid4() novo."""
    client.delete(
        collection_name=collection,
        points_selector=Filter(must=[FieldCondition(key="source", match=MatchValue(value=source))]),
    )


def embed_and_upsert(client, collection, embeddings, chunks: list[str], source: str) -> None:
    delete_existing_points_for_source(client, collection, source)

    for i in range(0, len(chunks), EMBED_BATCH_SIZE):
        batch = chunks[i : i + EMBED_BATCH_SIZE]
        vectors = embeddings.embed_documents(batch)
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

    # Collection garantida UMA VEZ por execucao - nao mais dentro do
    # loop de batch (bug de code review: get_collections() sendo
    # chamado a cada 16 chunks, por arquivo).
    vector_size = probe_vector_size(embeddings)
    ensure_collection(client, cfg["collection"], vector_size)

    for idx, path in enumerate(pending, start=1):
        rel = path.relative_to(source_dir)
        print(f"[{target}] ({idx}/{len(pending)}) processando: {rel}")
        try:
            text = extract_text(path)
            chunks = splitter.split_text(text)
            if not chunks:
                print("    [aviso] nenhum texto extraido, pulando")
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
INGESTEOF

echo "=== 2/3 - Reescrevendo app/rag/retriever.py (singletons + score_threshold) ==="
cat > app/rag/retriever.py << 'RETRIEVEREOF'
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
RETRIEVEREOF

echo "=== 3/3 - Estendendo guardrail no graph.py para contexto vazio ==="
python3 - << 'PYEOF'
from pathlib import Path

path = Path("app/agent/graph.py")
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

marker = "    data = state.get(\"connector_data\")\n"
target_idx = None
for i, line in enumerate(lines):
    if line == marker and "capped" in "".join(lines[i : i + 8]):
        target_idx = i
        break

if target_idx is None:
    print("AVISO: bloco do guardrail nao encontrado - verifique manualmente.")
else:
    extra = (
        "\n"
        "    # Guardrail adicional: se o retriever nao encontrou NENHUM\n"
        "    # documento acima do score_threshold (contexto vazio) e nao\n"
        "    # ha dado de conector, tambem nao ha base solida - mesmo\n"
        "    # raciocinio do guardrail de fallback, aplicado aqui.\n"
        "    if not state.get(\"retrieved_context\") and not data:\n"
        "        original_confidence = float(diagnosis.get(\"confidence\", 0.0))\n"
        "        capped = min(original_confidence, 0.3)\n"
        "        if capped < original_confidence:\n"
        "            diagnosis[\"confidence\"] = capped\n"
        "            diagnosis[\"matched_source\"] = None\n"
        "            diagnosis[\"probable_root_cause\"] = (\n"
        "                \"[confianca limitada - nenhum documento relevante encontrado] \"\n"
        "                f\"{diagnosis.get('probable_root_cause', '')}\"\n"
        "            )\n"
    )
    # insere logo apos o bloco existente de guardrail do conector
    insert_at = target_idx
    while not lines[insert_at].strip().startswith("return {\"diagnosis\": diagnosis}"):
        insert_at += 1
    lines.insert(insert_at, extra)
    Path("app/agent/graph.py").write_text("".join(lines), encoding="utf-8")
    print("Guardrail de contexto vazio adicionado.")
PYEOF

echo "=== Sync + lint ==="
uv sync
uv run ruff check --fix app/rag/ingest.py app/rag/retriever.py app/agent/graph.py
uv run ruff format app/rag/ingest.py app/rag/retriever.py app/agent/graph.py

echo
echo "============================================================"
echo "Correcoes aplicadas. Como o score_threshold e novo, o dataset"
echo "atual precisa ser REINDEXADO (o filtro so se aplica na consulta,"
echo "os pontos ja gravados continuam validos, mas confirme com um"
echo "teste completo):"
echo
echo "  uv run pytest -v"
echo
echo "Se algum teste falhar por causa do score_threshold cortando um"
echo "resultado que antes passava, ajuste DEFAULT_SCORE_THRESHOLD em"
echo "app/rag/retriever.py (hoje em 0.5) com base no que o teste"
echo "reportar como score real."
echo "============================================================"
