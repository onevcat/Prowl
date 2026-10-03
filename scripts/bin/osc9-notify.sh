#!/usr/bin/env bash
set -euo pipefail

body=${1:-"Hello from OSC 9"}
count=${2:-"3"}
sleep_seconds=${3:-"0.1"}

for i in $(seq 1 "$count"); do
  if [ "$count" -gt 1 ]; then
    printf '\033]9;%s %s/%s\a' "$body" "$i" "$count"
  else
    printf '\033]9;%s\a' "$body"
  fi
  sleep "$sleep_seconds"
done
