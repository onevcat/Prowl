# Heartbeat for raw `xcodebuild test` and `swift test` output.
#
# xcsift prints its report only after the test run exits, so a long run shows
# nothing for minutes. This filter reads the same raw stream and prints a
# short progress line every INTERVAL test cases, plus every failure, build
# error, and phase change as soon as it appears. Point it at stderr so the
# structured xcsift report on stdout stays clean.
#
# It understands the per-case lines of xcodebuild ("Test case 'X/y()' passed
# on 'My Mac'"), XCTest under swift test ("Test Case '-[X y]' passed (0.1
# seconds)"), and Swift Testing under swift test ("<symbol> Test y() passed
# after 0.1 seconds"). Each stream uses exactly one of these shapes.
#
# Counts are raw "Test case" lines, so a parameterized test counts once per
# argument; the xcsift report and assert-xcresult-tests.sh stay authoritative.
#
# Usage: xcodebuild test 2>&1 | tee >(awk -f scripts/test-progress.awk >&2) | xcsift
# Environment: PROWL_TEST_PROGRESS_LABEL prefixes every line (which pass is
# running); PROWL_TEST_PROGRESS_INTERVAL sets the count cadence (default 250).
BEGIN {
  interval = ENVIRON["PROWL_TEST_PROGRESS_INTERVAL"] + 0
  if (interval < 1) interval = 250
  # Names the xcodebuild pass (for example the result bundle) when several run in a row.
  label = ENVIRON["PROWL_TEST_PROGRESS_LABEL"]
  sub(/\.xcresult$/, "", label)
  if (label != "") label = label ": "
  passed = failed = skipped = compiled = 0
}

function now(   t) {
  "date +%T" | getline t
  close("date +%T")
  return t
}

# Drops the leading status symbol and padding from a Swift Testing line.
function strip(line) {
  sub(/^[^A-Za-z]+/, "", line)
  return line
}

function say(message) {
  printf "[%s] %s%s\n", now(), label, message
  fflush()
}

function tick() {
  total = passed + failed + skipped
  if (total % interval == 0) say(passed " passed, " failed " failed, " skipped " skipped")
}

# xcodebuild (Swift Testing and XCTest) and XCTest under swift test print one
# quoted test name per finished case.
/^Test [Cc]ase '.*' passed/  { passed++; tick(); next }
/^Test [Cc]ase '.*' skipped/ { skipped++; tick(); next }
/^Test [Cc]ase '.*' failed/  { failed++; say("FAIL " $0); next }

# Swift Testing under swift test prefixes each line with a status symbol.
/^[^A-Za-z]*Test run started\.$/                  { say("Swift Testing started"); next }
/^[^A-Za-z]*Test run with 0 tests /               { next }
/^[^A-Za-z]*Test run with [0-9]+ tests? /         { say(strip($0)); next }
/^[^A-Za-z]*Test (case )?.* passed after /        { passed++; tick(); next }
/^[^A-Za-z]*Test (case )?.* skipped/              { skipped++; tick(); next }
/^[^A-Za-z]*Test (case )?.* failed after /        { failed++; say("FAIL " strip($0)); next }
/^[^A-Za-z]*Test (case )?.* recorded an issue at / { say(strip($0)); next }

# XCTest under swift test brackets the run with the 'All tests' or
# 'Selected tests' suite; per-class suites are noise.
/^Test Suite '(All|Selected) tests' started/ { say("XCTest started"); next }

/^Testing started/ { say("testing started"); next }
/^\*\* (TEST|BUILD) (SUCCEEDED|FAILED) \*\*/ { say($0); next }
/^Build complete!/ { say($0); next }

# One line when the app binary links: the build phase is nearly over.
/^Ld .*\.app\/Contents\/MacOS\// { say("app binary linked"); next }
/^(SwiftCompile|CompileSwift) / {
  compiled++
  if (compiled % 500 == 0) say(compiled " compile steps")
  next
}

# Compiler diagnostics and fatal xcodebuild errors.
/: error:/ || /^xcodebuild: error:/ || /^error:/ { say($0); next }

# xcodebuild can flush buffered test-case lines after its own summary, so the
# final tally waits for the end of the stream.
END {
  if (passed + failed + skipped > 0) say("done: " passed " passed, " failed " failed, " skipped " skipped")
}
