#!/bin/bash
set -euo pipefail

# A failed assertion must say where it failed: on CI the log is all there is.
set -E
trap 'echo "${BASH_SOURCE[0]##*/}:$LINENO: failed: $BASH_COMMAND" >&2' ERR

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN="$TEST_ROOT/bin"
PERL_LIB="$TEST_ROOT/perl5"
MEASUREMENTS="$TEST_ROOT/measurements"
mkdir -p "$BIN" "$PERL_LIB" "$MEASUREMENTS"

REAL_PS=$(command -v ps)

# Every stub appends "<name> <pid>" to PROWL_FAKE_CALLS when it is set. PIDs are
# handed out in increasing order, so a smaller PID than sample's ran before it.
cat > "$BIN/ps" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\$*" == *"-o time="* ]]; then
  if [ -n "\${PROWL_FAKE_CALLS:-}" ]; then echo "ps-time \$\$" >> "\$PROWL_FAKE_CALLS"; fi
  state="$TEST_ROOT/ps-state"
  value=0
  if [ -f "\$state" ]; then value=1; fi
  : > "\$state"
  printf '00:00:0%s\n' "\$value"
  exit 0
fi
if [ -n "\${PROWL_FAKE_CALLS:-}" ]; then echo "ps \$\$" >> "\$PROWL_FAKE_CALLS"; fi
if [[ "\$*" == *"-o etime="* ]]; then
  echo '00:10'
elif [[ "\$*" == *"pid,%cpu,comm"* ]]; then
  printf '  PID %%CPU COMM\n%s 75.0 /Applications/Prowl Debug.app/Contents/MacOS/ProwlApp\n' "\${PROWL_PID:-1}"
else
  exec "$REAL_PS" "\$@"
fi
EOF

cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$BIN/uptime" <<'EOF'
#!/bin/bash
if [ -n "${PROWL_FAKE_CALLS:-}" ]; then echo "uptime $$" >> "$PROWL_FAKE_CALLS"; fi
echo '01:00  up 1 day,  load averages: 1.00 2.00 3.00'
EOF

cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
if [ -n "${PROWL_FAKE_CALLS:-}" ]; then echo "sysctl $$" >> "$PROWL_FAKE_CALLS"; fi
echo 12
EOF

# The capture script calls /usr/bin/perl by absolute path, so PERL5OPT is the only
# way to see those calls.
cat > "$PERL_LIB/CallLog.pm" <<'EOF'
package CallLog;
if ($ENV{PROWL_FAKE_CALLS}) {
  open my $log, '>>', $ENV{PROWL_FAKE_CALLS} or die "CallLog: $!";
  print $log "perl $$\n";
  close $log;
}
1;
EOF

cat > "$BIN/prowl" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ -n "${PROWL_FAKE_CALLS:-}" ]; then echo "prowl $$" >> "$PROWL_FAKE_CALLS"; fi
wait_for() {
  for _ in $(seq 1 3000); do
    [ -f "$1" ] && return 0
    /bin/sleep 0.01
  done
}
case "$1" in
  agents)
    if [ -n "${PROWL_FAKE_AGENTS_STALLS:-}" ]; then exec /bin/sleep 30; fi
    echo '{"ok":true,"data":{"agents":[{"status":"working"},{"status":"idle"}]}}'
    ;;
  list)
    if [ -n "${PROWL_FAKE_LIST_STALLS:-}" ]; then exec /bin/sleep 30; fi
    # Answer only once sampling has ended.
    if [ -n "${PROWL_FAKE_LIST_AFTER_SAMPLE:-}" ]; then wait_for "$PROWL_FAKE_TIMES_DIR/sample-ended"; fi
    # Answer this many seconds after sampling began.
    if [ -n "${PROWL_FAKE_LIST_DELAY:-}" ]; then
      wait_for "$PROWL_FAKE_TIMES_DIR/sample-started"
      /bin/sleep "$PROWL_FAKE_LIST_DELAY"
    fi
    if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
      /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$PROWL_FAKE_TIMES_DIR/list-answered"
    fi
    cat <<'JSON'
{"ok":true,"data":{"items":[
  {"worktree":{"id":"w1"},"tab":{"id":"t1","selected":true},"pane":{"id":"p1","focused":true,"visible":true}},
  {"worktree":{"id":"w1"},"tab":{"id":"t1","selected":true},"pane":{"id":"p2","focused":false,"visible":true}},
  {"worktree":{"id":"w2"},"tab":{"id":"t2","selected":true},"pane":{"id":"p3","focused":false,"visible":false}}
]}}
JSON
    ;;
  *) exit 64 ;;
esac
EOF

# Only PROWL_FAKE_SOCKET_OWNER (default: PROWL_PID) serves a socket, at
# PROWL_FAKE_SERVED_SOCKET (default: the CLI's default path).
cat > "$BIN/lsof" <<'EOF'
#!/bin/bash
if [ -n "${PROWL_FAKE_CALLS:-}" ]; then echo "lsof $$" >> "$PROWL_FAKE_CALLS"; fi
pid=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -p ]; then
    pid=$2
    shift 2
  else
    shift
  fi
done
[ "$pid" = "${PROWL_FAKE_SOCKET_OWNER:-$PROWL_PID}" ] || exit 1
printf 'p%s\nf5\nn%s\n' "$pid" \
  "${PROWL_FAKE_SERVED_SOCKET:-$HOME/Library/Application Support/com.onevcat.prowl/cli.sock}"
EOF

cat > "$BIN/top" <<EOF
#!/bin/bash
for _ in \$(seq 1 20); do echo "\${PROWL_PID:-1} 50.0"; done
EOF

# Like sample(1), the fake writes a Date/Time header stamped when sampling begins. In
# the timing cases it also takes PROWL_FAKE_SAMPLE_ATTACH seconds to begin, samples
# for its requested duration, and records its start and end.
cat > "$BIN/sample" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ -n "${PROWL_FAKE_CALLS:-}" ]; then echo "sample $$" >> "$PROWL_FAKE_CALLS"; fi
seconds=$2
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
if [ -n "${PROWL_FAKE_SAMPLE_ATTACH:-}" ]; then /bin/sleep "$PROWL_FAKE_SAMPLE_ATTACH"; fi
stamp=$(/usr/bin/perl -MPOSIX=strftime -MTime::HiRes=time -e '
  my $t = time;
  printf "%.3f|%s.%03d %s\n", $t, strftime("%Y-%m-%d %H:%M:%S", localtime $t),
    ($t - int $t) * 1000, strftime("%z", localtime $t);')
if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
  echo "${stamp%%|*}" > "$PROWL_FAKE_TIMES_DIR/sample-started"
  /bin/sleep "$seconds"
fi
{
  echo "Date/Time:       ${stamp#*|}"
  cat <<'SAMPLE'
    100 Thread_1 DispatchQueue_1: com.apple.main-thread
      11 stepTransactionFlush
      13 GraphHost.flushTransactions()
      7 flushTransactions
      17 addGlyph
      19 rebuildRow
      23 wyhash
SAMPLE
} > "$output"
if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$PROWL_FAKE_TIMES_DIR/sample-ended.tmp"
  mv "$PROWL_FAKE_TIMES_DIR/sample-ended.tmp" "$PROWL_FAKE_TIMES_DIR/sample-ended"
fi
EOF

chmod +x "$BIN"/*

# grep -q that shows what it searched when the pattern is absent. The text is the file in the
# third argument, or stdin.
expect_grep() {
  local flag=$1 pattern=$2 source=${3:-} text
  if [ -n "$source" ]; then text=$(cat "$source" 2>&1 || true); else text=$(cat); fi
  if ! grep "$flag" -q -- "$pattern" <<< "$text"; then
    {
      echo "${BASH_SOURCE[0]##*/}:${BASH_LINENO[0]}: ${source:-the output} does not contain: $pattern"
      echo "--- it holds (last 40 lines) ---"
      tail -n 40 <<< "$text"
    } >&2
    exit 1
  fi
}

# Runs capture-cpu-spike.sh against the stubs with a one-second sample; extra
# VAR=value arguments configure the stubs.
run_spike() {
  local dir=$1
  shift
  rm -f "$TEST_ROOT/ps-state"
  mkdir -p "$dir"
  env PATH="$BIN:$PATH" PROWL_PID=$$ PROWL_MEASURE_DIR="$dir" \
    PROWL_SPIKE_INTERVAL=1 PROWL_SPIKE_MAX_WAIT=1 PROWL_SPIKE_CONSECUTIVE=1 \
    "$@" bash "$ROOT/scripts/capture-cpu-spike.sh" 50 1
}

spike_dir() {
  find "$1/spikes" -mindepth 1 -maxdepth 1 -type d
}

# The saved pane snapshot must have been answered while the fake sample was sampling.
# sample-started holds the same value as the Date/Time header the fake writes, so the
# start bound is the one the capture script reads.
assert_snapshot_inside_sample() {
  local times=$1
  local started ended answered
  started=$(cat "$times/sample-started")
  ended=$(cat "$times/sample-ended")
  answered=$(cat "$times/list-answered")
  awk -v start="$started" -v end="$ended" -v answered="$answered" \
    'BEGIN { exit !(answered >= start && answered <= end) }' || {
    echo "pane snapshot answered at $answered, outside the sample from $started to $ended" >&2
    exit 1
  }
}

# Nothing runs between confirming the spike and launching sample.
CALLS="$TEST_ROOT/calls"
SPIKE_OUTPUT=$(run_spike "$MEASUREMENTS" PROWL_FAKE_CALLS="$CALLS" PERL5LIB="$PERL_LIB" PERL5OPT=-MCallLog)
test -f "$(spike_dir "$MEASUREMENTS")/panes.json"
expect_grep -F \
  'pane mix: total=3   visible=2   focused=1   tabs=2   selected_tabs=2   worktrees=2' \
  <<< "$SPIKE_OUTPUT"
awk '
  $1 == "sample" { sample = $2 }
  { name[NR] = $1; pid[NR] = $2 }
  END {
    if (!sample) { print "sample never ran"; exit 1 }
    for (i = 1; i <= NR; i++)
      if (name[i] != "sample" && name[i] != "ps-time" && pid[i] < sample) {
        print name[i] " (pid " pid[i] ") ran before sample (pid " sample ")"
        failed = 1
      }
    exit failed
  }' "$CALLS" >&2

# A stalled prowl list neither blocks nor delays the capture.
STALL_MEASUREMENTS="$TEST_ROOT/stall-measurements"
STALL_STARTED=$SECONDS
STALL_OUTPUT=$(run_spike "$STALL_MEASUREMENTS" PROWL_FAKE_LIST_STALLS=1)
STALL_ELAPSED=$((SECONDS - STALL_STARTED))
[ "$STALL_ELAPSED" -lt 10 ] || { echo "stalled prowl list held the spike capture for ${STALL_ELAPSED}s" >&2; exit 1; }
STALL_DIR=$(spike_dir "$STALL_MEASUREMENTS")
expect_grep -F 'stepTransactionFlush' "$STALL_DIR/sample.txt"
expect_grep -F '"ok":false' "$STALL_DIR/panes.json"
expect_grep -F 'pane mix: CLI unavailable (no answer within 6s)' <<< "$STALL_OUTPUT"

# A slow prowl agents does not hold back the pane snapshot.
TIMES="$TEST_ROOT/times"
mkdir -p "$TIMES"
SLOW_AGENTS_OUTPUT=$(run_spike "$TEST_ROOT/slow-agents-measurements" \
  PROWL_FAKE_AGENTS_STALLS=1 PROWL_FAKE_TIMES_DIR="$TIMES")
SLOW_AGENTS_DIR=$(spike_dir "$TEST_ROOT/slow-agents-measurements")
expect_grep -F '"ok":false' "$SLOW_AGENTS_DIR/agents.json"
expect_grep -F '"ok":true' "$SLOW_AGENTS_DIR/panes.json"
expect_grep -F 'pane mix: total=3' <<< "$SLOW_AGENTS_OUTPUT"
assert_snapshot_inside_sample "$TIMES"

# A snapshot that arrives after sampling has ended is refused.
LATE_TIMES="$TEST_ROOT/late-times"
mkdir -p "$LATE_TIMES"
LATE_LIST_OUTPUT=$(run_spike "$TEST_ROOT/late-list-measurements" \
  PROWL_FAKE_AGENTS_STALLS=1 PROWL_FAKE_LIST_AFTER_SAMPLE=1 PROWL_FAKE_TIMES_DIR="$LATE_TIMES")
LATE_LIST_DIR=$(spike_dir "$TEST_ROOT/late-list-measurements")
if grep -Fq '"ok":true' "$LATE_LIST_DIR/panes.json"; then
  assert_snapshot_inside_sample "$LATE_TIMES"
fi
expect_grep -F '"ok":false' "$LATE_LIST_DIR/panes.json"
expect_grep -F 'pane mix: CLI unavailable (answered after sampling ended)' <<< "$LATE_LIST_OUTPUT"

# sample(1) takes time to attach before it samples. Here the fake takes 0.5 s, longer
# than the query offset, so a prowl list that answers at once does so before sampling
# begins. That snapshot is refused.
EARLY_TIMES="$TEST_ROOT/early-times"
mkdir -p "$EARLY_TIMES"
EARLY_OUTPUT=$(run_spike "$TEST_ROOT/early-measurements" \
  PROWL_FAKE_SAMPLE_ATTACH=0.5 PROWL_FAKE_TIMES_DIR="$EARLY_TIMES")
EARLY_DIR=$(spike_dir "$TEST_ROOT/early-measurements")
awk -v start="$(cat "$EARLY_TIMES/sample-started")" -v answered="$(cat "$EARLY_TIMES/list-answered")" \
  'BEGIN { exit !(answered < start) }' || {
  echo "the early prowl list answered after sampling began; the case tests nothing" >&2
  exit 1
}
grep -Fq 'answered before sampling started' "$EARLY_DIR/panes.json" || {
  echo "pane snapshot answered before sampling started was kept: $(tr -d '\n' < "$EARLY_DIR/panes.json" | cut -c1-60)" >&2
  exit 1
}
expect_grep -F 'pane mix: CLI unavailable (answered before sampling started)' <<< "$EARLY_OUTPUT"

# With the same attach delay, a snapshot answered late in the sampling, but still
# inside it, is kept.
ATTACH_TIMES="$TEST_ROOT/attach-times"
mkdir -p "$ATTACH_TIMES"
ATTACH_OUTPUT=$(run_spike "$TEST_ROOT/attach-measurements" \
  PROWL_FAKE_SAMPLE_ATTACH=0.5 PROWL_FAKE_LIST_DELAY=0.6 PROWL_FAKE_TIMES_DIR="$ATTACH_TIMES")
ATTACH_DIR=$(spike_dir "$TEST_ROOT/attach-measurements")
grep -Fq '"ok":true' "$ATTACH_DIR/panes.json" || {
  echo "pane snapshot answered inside the sample was discarded: $(cat "$ATTACH_DIR/panes.json")" >&2
  exit 1
}
expect_grep -F 'pane mix: total=3' <<< "$ATTACH_OUTPUT"
assert_snapshot_inside_sample "$ATTACH_TIMES"

# The CLI answers for another app than the sampled one: its socket points elsewhere,
# or another process serves the default socket. Neither answer is kept.
FOREIGN_SOCKET="$TEST_ROOT/other-app.sock"
FOREIGN_OUTPUT=$(run_spike "$TEST_ROOT/foreign-measurements" PROWL_CLI_SOCKET="$FOREIGN_SOCKET")
FOREIGN_DIR=$(spike_dir "$TEST_ROOT/foreign-measurements")
for file in agents panes; do
  grep -Fq "\"reason\":\"CLI socket $FOREIGN_SOCKET is not served by pid $$\"" "$FOREIGN_DIR/$file.json" || {
    echo "$file snapshot from another app's socket was kept: $(cut -c1-60 < "$FOREIGN_DIR/$file.json")" >&2
    exit 1
  }
done
expect_grep -F "CLI unavailable (CLI socket $FOREIGN_SOCKET is not served by pid $$)" <<< "$FOREIGN_OUTPUT"
expect_grep -F "pane mix: CLI unavailable (CLI socket $FOREIGN_SOCKET is not served by pid $$)" <<< "$FOREIGN_OUTPUT"

OTHER_OWNER_OUTPUT=$(run_spike "$TEST_ROOT/other-owner-measurements" PROWL_FAKE_SOCKET_OWNER=1)
expect_grep -F 'pane mix: CLI unavailable (CLI socket ' <<< "$OTHER_OWNER_OUTPUT"
expect_grep -F "is not served by pid $$" "$(spike_dir "$TEST_ROOT/other-owner-measurements")/panes.json"

# A socket override that the sampled process serves is honored.
OVERRIDE_OUTPUT=$(run_spike "$TEST_ROOT/override-measurements" \
  PROWL_CLI_SOCKET="$FOREIGN_SOCKET" PROWL_FAKE_SERVED_SOCKET="$FOREIGN_SOCKET")
expect_grep -F 'pane mix: total=3' <<< "$OVERRIDE_OUTPUT"

rm -f "$TEST_ROOT/ps-state"
MEASURE_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$MEASUREMENTS" \
    bash "$ROOT/scripts/measure-agent-detection-cpu.sh"
)

MEASURE_DIR=$(find "$MEASUREMENTS" -mindepth 1 -maxdepth 1 -type d ! -name spikes)
test -f "$MEASURE_DIR/panes.json"
expect_grep -F \
  'total=3   visible=2   focused=1   tabs=2   selected_tabs=2   worktrees=2' \
  <<< "$MEASURE_OUTPUT"
expect_grep -E '11\.00% +-[[:space:]]+stepTransactionFlush' <<< "$MEASURE_OUTPUT"
expect_grep -E '13\.00% +-[[:space:]]+GraphHost\.flushTransactions\(\)' <<< "$MEASURE_OUTPUT"
expect_grep -E '7\.00% +-[[:space:]]+flushTransactions \(excluding GraphHost\)' <<< "$MEASURE_OUTPUT"
expect_grep -E '17\.00% +-[[:space:]]+addGlyph' <<< "$MEASURE_OUTPUT"
expect_grep -E '19\.00% +-[[:space:]]+rebuildRow' <<< "$MEASURE_OUTPUT"
expect_grep -E '23\.00% +-[[:space:]]+wyhash' <<< "$MEASURE_OUTPUT"

# The steady-state profiler does not query a CLI that answers for another app.
FOREIGN_CALLS="$TEST_ROOT/foreign-calls"
FOREIGN_MEASURE_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$TEST_ROOT/foreign-steady-measurements" \
    PROWL_CLI_SOCKET="$FOREIGN_SOCKET" \
    PROWL_FAKE_CALLS="$FOREIGN_CALLS" \
    bash "$ROOT/scripts/measure-agent-detection-cpu.sh"
)
FOREIGN_MEASURE_DIR=$(find "$TEST_ROOT/foreign-steady-measurements" -mindepth 1 -maxdepth 1 -type d)
if grep -q '^prowl ' "$FOREIGN_CALLS"; then
  echo "the steady-state profiler queried a CLI socket that another app serves" >&2
  exit 1
fi
expect_grep -F "is not served by pid $$" "$FOREIGN_MEASURE_DIR/agents.json"
expect_grep -F "is not served by pid $$" "$FOREIGN_MEASURE_DIR/panes.json"
[ "$(grep -Fc "CLI unavailable (CLI socket $FOREIGN_SOCKET is not served by pid $$)" <<< "$FOREIGN_MEASURE_OUTPUT")" -eq 2 ]

echo 'performance measurement script tests passed'
