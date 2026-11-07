#!/usr/bin/env bash
set -u

hosts=(7.150.2.138 7.150.7.109 7.150.4.220 7.150.6.168)

send_all() {
  local action=$1 i host port
  local -a args=()

  for ((i = 0; i < 64; i++)); do
    ((i > 0)) && args+=(--next)
    host=${hosts[i / 16]}
    port=$((9100 + i))
    args+=(--noproxy '*' -fsS --connect-timeout 3 --max-time 15
           -X POST -o /dev/null "http://${host}:${port}/${action}_profile")
  done

  curl --parallel --parallel-immediate --parallel-max 64 --fail-early "${args[@]}"
}

failed=0
send_all start || failed=1
sleep 0.9
send_all stop || failed=1
exit "$failed"
