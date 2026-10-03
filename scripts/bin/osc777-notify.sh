#!/usr/bin/env bash
set -euo pipefail

title=${1:-"Title"}
body=${2:-"Body"}
count=${3:-"3"}
sleep_seconds=${4:-"0.1"}

for i in $(seq 1 "$count"); do
  if [ "$count" -gt 1 ]; then
    printf '\033]777;notify;%s %s/%s;%s\a' "$title" "$i" "$count" "$body"
  else
    printf '\033]777;notify;%s;%s\a' "$title" "$body"
  fi
  sleep "$sleep_seconds"
done
