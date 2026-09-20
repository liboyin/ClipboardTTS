#!/usr/bin/env bash
set -euo pipefail

# Verify check-coverage.sh's fail-closed policy against synthetic xccov reports.
#
# Run this whenever that policy changes. It needs no build, no result bundle, and no network: it
# drives the real gate end to end through the .json report form, so what it verifies is the script
# the gate actually runs. The gated population still comes from the sources on disk, which is why
# the fixtures name the repository's own gated files rather than invented ones.

cd "$(dirname "$0")"

REPO="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

# make_fixture <mode> <output-path> — write an xccov-shaped report describing <mode>.
make_fixture() {
  MODE="$1" OUT="$2" REPO="$REPO" /usr/bin/python3 - <<'PY'
import glob, json, os

mode = os.environ["MODE"]
repo = os.environ["REPO"]
gated = sorted(glob.glob("Sources/Managers/**/*.swift", recursive=True))
assert gated, "expected gated sources on disk"

# A checkout whose own parent directory is named Sources must still name its files the way the
# gated population does.
prefix = "/private/tmp/Sources/Checkout" if mode == "nested-sources-prefix" else repo


def entry(path, covered, executable):
    return {
        "path": os.path.join(prefix, path),
        "name": os.path.basename(path),
        "coveredLines": covered,
        "executableLines": executable,
        "lineCoverage": (covered / executable) if executable else 0.0,
    }


covered_lines = 50 if mode == "below-threshold" else 95
files = [entry(path, covered_lines, 100) for path in gated]

if mode == "empty-gated":
    files = []
elif mode == "gated-file-absent":
    files = files[1:]
elif mode == "gated-file-zero-lines":
    files[0] = entry(gated[0], 0, 0)
elif mode == "stale-gated-source":
    # Every current gated source uncovered, and one record for a manager that no longer exists
    # carrying enough coverage to clear the threshold on its own.
    files = [entry(path, 0, 1) for path in gated]
    files.append(entry("Sources/Managers/DeletedLegacyManager.swift", 1000, 1000))
elif mode == "duplicate-gated-source":
    files.append(entry(gated[0], 100, 100))
elif mode == "record-missing-count":
    del files[0]["executableLines"]
elif mode == "record-without-path":
    del files[0]["path"]
elif mode == "record-not-an-object":
    files[0] = gated[0]
elif mode == "negative-counts":
    files = [entry(path, -1, -1) for path in gated]
elif mode == "boolean-counts":
    files = [entry(path, True, True) for path in gated]
elif mode == "covered-exceeds-executable":
    files = [entry(path, 2, 1) for path in gated]
elif mode == "boundary-counts":
    # Fully covered gated sources and a wholly uncovered exempt one: both are ordinary readings.
    files = [entry(path, 100, 100) for path in gated]
    files.append(entry("Sources/Views/MenuBarView.swift", 0, 100))
elif mode == "record-with-minimal-fields":
    # The gate reads a path and the two line counts; nothing else about a record is required.
    files[0] = {key: files[0][key] for key in ("path", "coveredLines", "executableLines")}

if mode == "exempt-group-zero-lines":
    files.append(entry("Sources/Views/MenuAlertPresenter.swift", 0, 0))
elif mode != "exempt-sources-absent":
    files.append(entry("Sources/Views/SettingsView.swift", 10, 100))
    files.append(entry("Sources/SecretStore.swift", 10, 100))
    if mode == "stale-exempt-source":
        files.append(entry("Sources/Views/RemovedView.swift", 10, 100))

target_name = "SomeOtherApp.app" if mode == "missing-target" else "ClipboardTTSApp.app"
target = {"name": target_name, "files": None if mode == "target-files-not-a-list" else files}
report = {"targets": [target, {"name": "ClipboardTTSAppTests.xctest", "files": []}]}
if mode == "no-targets":
    report = {"unexpected": []}

with open(os.environ["OUT"], "w") as out:
    json.dump(report, out)
PY
}

# check <label> <report-path> <exit-status> <substring> [gate-script]
# A case that expects a failure also requires that no PASS verdict was printed, so a guard that runs
# after the verdict rather than before it is not mistaken for one that refused it.
check() {
  local label="$1" fixture="$2" want_status="$3" want_text="$4"
  local script="${5:-$REPO/check-coverage.sh}"

  local output status
  set +e
  output="$("$script" "$fixture" 2>&1)"
  status=$?
  set -e

  local wrongly_passed=0
  if [ "$want_status" -ne 0 ] && printf '%s' "$output" | grep -qF -- "PASS: Managers line coverage"; then
    wrongly_passed=1
  fi

  if [ "$status" -ne "$want_status" ] || [ "$wrongly_passed" -ne 0 ] \
    || ! printf '%s' "$output" | grep -qF -- "$want_text"; then
    printf 'FAIL %s: wanted exit %s containing "%s", got exit %s:\n%s\n\n' \
      "$label" "$want_status" "$want_text" "$status" "$output"
    failures=$((failures + 1))
  else
    printf 'ok   %s (exit %s)\n' "$label" "$status"
  fi
}

# expect <label> <mode> <exit-status> <substring> [gate-script]
expect() {
  local label="$1" mode="$2"
  make_fixture "$mode" "$WORK/$label.json"
  check "$label" "$WORK/$label.json" "$3" "$4" "${5:-}"
}

# A measured report still decides on its measured coverage.
expect measured-report-passes valid 0 "PASS: Managers line coverage"
expect measured-report-below-threshold-fails below-threshold 1 "FAIL: Managers line coverage"

# The verdict is computed over exactly the gated sources on disk: one that the report omits, one it
# counts although nothing on disk carries that name, and one it counts twice are each refused.
expect empty-gated-population empty-gated 2 "gated sources missing from the coverage report"
expect one-gated-source-absent gated-file-absent 2 "gated sources missing from the coverage report"
expect stale-gated-source-not-counted stale-gated-source 2 \
  "coverage report counts gated sources that are not on disk"
expect gated-source-counted-twice duplicate-gated-source 2 \
  "coverage report counts a gated source more than once"
expect gated-source-without-executable-lines gated-file-zero-lines 2 \
  "gated sources report no executable lines"

# A report the gate cannot read is unmeasurable, never insufficient: none of these may exit 1.
expect missing-target missing-target 2 "ClipboardTTSApp.app target not found"
expect report-without-targets no-targets 2 "coverage report declares no targets"
expect target-files-not-a-list target-files-not-a-list 2 "declares no files"
expect record-without-a-path record-without-path 2 "file record without a path"
expect record-without-a-line-count record-missing-count 2 "is missing a line count"
expect record-that-is-not-an-object record-not-an-object 2 "file record that is not an object"

# Counts a report cannot mean are refused rather than averaged into a percentage.
expect negative-line-counts negative-counts 2 "counts -1 of -1 executable lines"
expect boolean-line-counts boolean-counts 2 "is missing a line count"
expect covered-exceeds-executable covered-exceeds-executable 2 "counts 2 of 1 executable lines"

printf '{ this is not json' > "$WORK/malformed.json"
check malformed-report "$WORK/malformed.json" 2 "coverage report is not valid JSON"

# A result bundle xccov cannot read reaches the same refusal rather than an empty measurement.
mkdir -p "$WORK/not-a-bundle.xcresult"
check unreadable-result-bundle "$WORK/not-a-bundle.xcresult" 2 "could not extract a coverage report"

# The exemption is not tightened by any of that: an exempt group with nothing to measure reports no
# percentage instead of 100%, and exempt sources may be absent from the report entirely.
expect exempt-group-without-lines-passes exempt-group-zero-lines 0 "PASS: Managers line coverage"
expect exempt-group-without-lines-reads-n-a exempt-group-zero-lines 0 "n/a"
expect exempt-sources-absent-passes exempt-sources-absent 0 "PASS: Managers line coverage"
expect stale-exempt-source-passes stale-exempt-source 0 "PASS: Managers line coverage"
expect record-with-minimal-fields-passes record-with-minimal-fields 0 "PASS: Managers line coverage"
expect fully-and-zero-covered-counts-pass boundary-counts 0 "PASS: Managers line coverage 100.00%"

# A checkout under a directory named Sources names its gated files the same way.
expect checkout-under-a-sources-parent nested-sources-prefix 0 "PASS: Managers line coverage"

# A gate run where the gated directory does not exist measures nothing and says so, rather than
# dividing by an empty population.
mkdir -p "$WORK/no-sources"
cp check-coverage.sh "$WORK/no-sources/check-coverage.sh"
expect no-gated-sources-on-disk valid 2 "no gated sources found under Sources/Managers/" \
  "$WORK/no-sources/check-coverage.sh"

# A report path that does not exist is not a pass either.
check absent-report "$WORK/never-written.json" 2 "not found"

echo
if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures coverage-gate verification case(s) failed."
  exit 1
fi
echo "PASS: every coverage-gate verification case held."
