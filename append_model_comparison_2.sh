#!/usr/bin/env bash
# ============================================================
# Adiciona secao 8 ("Segunda comparacao de modelo") as Decisoes
# de Arquitetura do README.
# Uso: rodar dentro de ~/sap-integration-copilot
#   bash append_model_comparison_2.sh
# ============================================================
set -e

if [ ! -f pyproject.toml ]; then
  echo "ERRO: rode este script dentro de ~/sap-integration-copilot"
  exit 1
fi

if grep -q "qwen3.6:35b-a3b" README.md 2>/dev/null; then
  echo "Secao ja parece existir no README, pulando."
  exit 0
fi

cat >> README.md << 'READMEEOF'

### 8. Segunda comparação de modelo: qwen3.6:35b-a3b avaliado e rejeitado

**Contexto:** meses após a decisão pelo `qwen2.5-coder:32b` (seção 4),
a Alibaba lançou o `qwen3.6:35b-a3b` (MoE, 36B total/3B ativos,
sucessor da série que havia sido descartada na primeira comparação).
Repetiu-se o mesmo processo formal via `promptfoo`, contra o mesmo
pipeline real e os mesmos 10 casos de teste — incluindo o caso crítico
(`IDoc travado` / conector RFC) repetido 3 vezes para medir
estabilidade.

**Resultado:** em 7 dos 10 casos, desempenho equivalente ou
ligeiramente superior ao modelo atual (respostas mais detalhadas,
confiança bem calibrada no caso de segurança do identificador
desconhecido). Porém, no caso crítico repetido 3 vezes, o
`qwen3.6:35b-a3b` **falhou nas 3 execuções de forma idêntica**: o
modelo não devolveu um JSON estruturado válido
(`"Nao foi possivel estruturar a resposta do modelo"`,
`confidence: 0.0`), enquanto o `qwen2.5-coder:32b` acertou as 3 vezes
com 90% de confiança.

**Decisão:** manter `qwen2.5-coder:32b` em produção. Uma falha
determinística e reproduzível (3/3) no cenário mais crítico do
pipeline desqualifica o candidato, independente do desempenho médio
nos demais casos — confiabilidade sob o caso mais exigente pesa mais
que desempenho médio.

**Valor do processo, não só do resultado:** esta comparação também
prova que a decisão de modelo não é estática — é revisitada com
critério formal sempre que surge um candidato relevante, com a mesma
metodologia e o mesmo pipeline real usados desde a primeira vez,
gerando decisões comparáveis ao longo do tempo.
READMEEOF

echo "Secao 8 adicionada ao README.md"
