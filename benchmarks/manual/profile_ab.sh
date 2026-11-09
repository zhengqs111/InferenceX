#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A/B 分开运行；在另一个终端手动 start/stop profile。
case "${1:-A}" in
  A|a) export INPUT="$DIR/requests-greedy.jsonl" ;;
  B|b) export INPUT="$DIR/requests-grammar.jsonl" ;;
  *) echo "用法：$0 A|B [--dry-run]" >&2; exit 2 ;;
esac
if (( $# )); then shift; fi

export BASE_URL="${BASE_URL:-http://7.150.1.10:12901}"
export MODEL="${MODEL:-glm-5}"
export CONCURRENCY="${CONCURRENCY:-128}"
export STREAM=0
source "$DIR/../benchmark_lib.sh"
check_env_vars BASE_URL MODEL INPUT
exec "${PYTHON:-python3}" "$DIR/profile.py" "$@"
