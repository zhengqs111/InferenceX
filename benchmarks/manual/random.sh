#!/usr/bin/env bash
set -eo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 修改这里：服务、模型、数据和压测参数。
PYTHON="${PYTHON:-python3}"
BASE_URL="${BASE_URL:-}"  # 填 Proxy 地址，如 http://192.168.1.10:8000，不带 /v1。
MODEL="${MODEL:-dsv41}"  # 服务端 --served-model-name。
MODEL_PATH="${MODEL_PATH:-}"  # 填客户端可访问的 V4.1 模型/tokenizer 目录。
TOKENIZER="${TOKENIZER:-$MODEL_PATH}"
TOKENIZER_MODE=deepseek_v41
NUM_PROMPTS=10
CONFIG_FILE="$ROOT/benchmarks/manual/existing-service.yaml"
CONFIG_KEY=existing-service
SEQ_LENS=1k1k  # 输入 1024 / 输出上限 1024；也支持 8k1k。
CONCURRENCIES=(1 2 5 16 32 64 128)
NUM_WARMUPS=1
REQUEST_RATE=inf
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"  # 专用服务默认不等待；有限流时自行增加。

cd "$ROOT"
source "$ROOT/benchmarks/benchmark_lib.sh"
check_env_vars BASE_URL MODEL MODEL_PATH TOKENIZER
mkdir -p "$ROOT/manual_results"
OUT="$(mktemp -d "$ROOT/manual_results/random-$(date +%Y%m%d-%H%M%S)-XXXXXX")"
echo "结果目录：$OUT"

for C in "${CONCURRENCIES[@]}"; do
  echo "并发 $C：等待 ${COOLDOWN_SECONDS}s 后开始"
  sleep "$COOLDOWN_SECONDS"
  "$PYTHON" "$ROOT/utils/manual_benchmark_existing_service.py" \
    --config-files "$CONFIG_FILE" --config-key "$CONFIG_KEY" \
    --base-url "$BASE_URL" --model-override "$MODEL_PATH" --served-model-name "$MODEL" \
    --seq-lens "$SEQ_LENS" --conc "$C" \
    --dataset-name random --tokenizer "$TOKENIZER" --tokenizer-mode "$TOKENIZER_MODE" \
    --num-prompts "$NUM_PROMPTS" --random-range-ratio 1.0 --random-num-workers 1 \
    --log-request-tokens \
    --num-warmups "$NUM_WARMUPS" --request-rate "$REQUEST_RATE" \
    --save-detailed --result-dir "$OUT" "$@" \
    2>&1 | tee "$OUT/random_c${C}.log"
done
echo "完成，结果在：$OUT；agg_*.json 是自动汇总结果。"
