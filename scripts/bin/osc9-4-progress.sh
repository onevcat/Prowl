#!/usr/bin/env bash
set -euo pipefail

sleep_seconds=${1:-"0.05"}

for progress in $(seq 1 100); do
  printf '\033]9;4;1;%s\a' "$progress"
  sleep "$sleep_seconds"
done

printf '\033]9;4;0\a'
