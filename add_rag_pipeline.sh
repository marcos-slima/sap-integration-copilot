#!/usr/bin/env bash
# ============================================================
# Adiciona o pipeline RAG (docs de exemplo + ingest + retriever)
# ao repositorio sap-integration-copilot
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash add_rag_pipeline.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

echo "=== 1/4 - Criando documentos de exemplo em data/sample_docs/ ==="
mkdir -p data/sample_docs

cat > data/sample_docs/idoc_status_51.md << 'DOC1EOF'
# IDoc Status 51 - Application Document Not Posted

## Sintoma
IDoc fica travado com status 51 na fila de entrada (transacao WE02/BD87).
O documento de aplicacao (ex: pedido de compra, fatura) nao e criado no
sistema de destino.

## Causas comuns
- Dados mestre incompletos ou inconsistentes no sistema receptor
  (ex: centro de custo inexistente, material nao cadastrado)
- Erro de mapeamento de campos entre o segmento do IDoc e a estrutura
  de dados esperada pela BAPI/funcao de processamento
- Autorizacao insuficiente do usuario tecnico usado no processamento
  em background

## Diagnostico
1. Verificar o texto de erro completo em WE02, aba "Status Records"
2. Identificar a funcao de processamento do IDoc e rodar em modo
   debug com o mesmo payload
3. Confirmar existencia dos dados mestre referenciados no IDoc

## Resolucao tipica
Corrigir o dado mestre ou o mapeamento, e reprocessar o IDoc via
BD87 (reprocessamento manual) ou aguardar o job de reprocessamento
automatico (RBDAPP01), se configurado.
DOC1EOF

cat > data/sample_docs/odata_timeout_cpi.md << 'DOC2EOF'
# OData Service Timeout em iFlow (CPI / Integration Suite)

## Sintoma
iFlow no SAP Integration Suite (CPI) falha com erro de timeout ao
consumir um servico OData exposto pelo SAP S/4HANA ou ECC (via
SAP Gateway).

## Causas comuns
- Query OData sem filtro trazendo volume muito grande de dados,
  estourando o tempo padrao de timeout do adapter (geralmente 60s)
- Sistema de backend sob alta carga no horario da execucao
- Pool de conexoes HTTP esgotado no Cloud Connector (cenario hibrido)

## Diagnostico
1. Verificar o Message Processing Log (MPL) do iFlow no
   monitoramento do Integration Suite
2. Checar o tempo de resposta do servico OData isoladamente fora
   do iFlow
3. Conferir status e conexoes ativas do Cloud Connector, se aplicavel

## Resolucao tipica
Adicionar paginacao ou filtros mais seletivos na query OData, e/ou
aumentar o timeout configurado no adapter do iFlow.
DOC2EOF

cat > data/sample_docs/rfc_connection_refused.md << 'DOC3EOF'
# RFC Destination - Connection Refused

## Sintoma
Chamada RFC (via SM59, ou de um sistema externo) falha com erro de
"Connection refused" ou "Partner not reached".

## Causas comuns
- Servico RFC/gateway do sistema de destino nao esta ativo
  (dispatcher parado, instancia em manutencao)
- Porta do gateway SAP bloqueada por firewall entre origem e destino
- Destino RFC configurado com host/instancia incorretos apos um
  refresh de ambiente

## Diagnostico
1. Testar a conexao diretamente em SM59 (Connection Test)
2. Verificar se o dispatcher do sistema de destino esta ativo
3. Confirmar regras de firewall/rede entre os hosts envolvidos

## Resolucao tipica
Corrigir o host/porta no destino RFC apos um refresh de ambiente,
ou acionar o time de infraestrutura para liberar a porta do gateway.
DOC3EOF

cat > data/sample_docs/cpi_http_401.md << 'DOC4EOF'
# CPI iFlow - Erro HTTP 401 (Unauthorized)

## Sintoma
iFlow no Integration Suite (CPI) recebe HTTP 401 ao chamar um
endpoint externo (ex: API REST de terceiro, ou outro sistema SAP).

## Causas comuns
- Credencial armazenada no Security Material expirada ou incorreta
- Token OAuth2 expirado e o adapter nao configurado para renovacao
  automatica
- Mudanca de senha/credencial no destino nao propagada para o
  Security Material do CPI

## Diagnostico
1. Verificar o Security Material usado no adapter (Credential Name)
2. Testar a credencial isoladamente fora do iFlow
3. Checar se o tipo de autenticacao configurado corresponde ao
   exigido pelo endpoint de destino

## Resolucao tipica
Atualizar a credencial no Security Material, ou reconfigurar o
fluxo OAuth2 se o token nao estiver sendo renovado automaticamente.
DOC4EOF

echo "=== 2/4 - Criando app/rag/ingest.py ==="
cat > app/rag/ingest.py << 'INGESTEOF'
"""Ingestao dos documentos de conhecimento no Qdrant.

Le os arquivos .md de data/sample_docs, divide em chunks, gera
embeddings via Ollama e indexa no Qdrant em uma collection dedicada.

Uso:
    uv run python -m app.rag.ingest
"""
from pathlib import Path
from uuid import uuid4

from langchain_text_splitters import MarkdownTextSplitter
from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

DOCS_DIR = Path(__file__).resolve().parents[2] / "data" / "sample_docs"
COLLECTION_NAME = "sap_incident_docs"
EMBEDDING_MODEL = "nomic-embed-text"
QDRANT_URL = "http://127.0.0.1:6333"


def load_documents() -> list[dict]:
    docs = []
    for path in sorted(DOCS_DIR.glob("*.md")):
        docs.append({"source": path.name, "text": path.read_text(encoding="utf-8")})
    return docs


def chunk_documents(docs: list[dict]) -> list[dict]:
    splitter = MarkdownTextSplitter(chunk_size=500, chunk_overlap=50)
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
    docs = load_documents()
    print(f"{len(docs)} documento(s) encontrados em {DOCS_DIR}")

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

echo "=== 3/4 - Criando app/rag/retriever.py ==="
cat > app/rag/retriever.py << 'RETRIEVEREOF'
"""Consulta (retrieval) na base de conhecimento indexada no Qdrant."""
from langchain_ollama import OllamaEmbeddings
from qdrant_client import QdrantClient

from app.rag.ingest import COLLECTION_NAME, EMBEDDING_MODEL, QDRANT_URL


def retrieve(query: str, top_k: int = 3) -> list[dict]:
    """Retorna os top_k chunks mais relevantes para a query.

    Cada item retornado tem: source, text, score.
    """
    embeddings = OllamaEmbeddings(model=EMBEDDING_MODEL)
    query_vector = embeddings.embed_query(query)

    client = QdrantClient(url=QDRANT_URL)
    results = client.query_points(
        collection_name=COLLECTION_NAME,
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

    query = " ".join(sys.argv[1:]) or "iFlow falhando com timeout"
    print(f"Query: {query}\n")
    for i, hit in enumerate(retrieve(query), start=1):
        print(f"--- resultado {i} (score={hit['score']:.4f}, fonte={hit['source']}) ---")
        print(hit["text"][:300])
        print()
RETRIEVEREOF

echo "=== 4/4 - Adicionando dependencia langchain-text-splitters ==="
uv add langchain-text-splitters

echo
echo "============================================================"
echo "Pipeline RAG adicionado. Proximos passos:"
echo
echo "1. Garantir que o modelo de embedding esta baixado no Ollama:"
echo "   ollama pull nomic-embed-text"
echo
echo "2. Rodar a ingestao (indexa os 4 docs de exemplo no Qdrant):"
echo "   cd ~/sap-integration-copilot"
echo "   uv run python -m app.rag.ingest"
echo
echo "3. Testar uma busca:"
echo "   uv run python -m app.rag.retriever \"iFlow falhando com erro 401\""
echo "============================================================"
