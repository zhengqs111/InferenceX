#!/usr/bin/env bash
set -u

hosts=(7.150.2.138 7.150.7.109 7.150.4.220 7.150.6.168)

send_all() {
  local action=$1 i host port pid status=0
  local -a pids=()

  for ((i = 0; i < 64; i++)); do
    host=${hosts[i / 16]}
    port=$((9100 + i))
    (
      curl --noproxy '*' -fsS --connect-timeout 3 --max-time 15 \
        -X POST "http://${host}:${port}/${action}_profile" >/dev/null \
        || { echo "${action}_profile failed: ${host}:${port}" >&2; exit 1; }
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  return "$status"
}

failed=0
send_all start || failed=1
sleep 0.9
send_all stop || failed=1
exit "$failed"
