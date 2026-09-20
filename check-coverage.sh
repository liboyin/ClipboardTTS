#!/usr/bin/env bash
set -euo pipefail

# Enforce line-coverage thresholds for the app target.
#
# Coverage in this project is LINE coverage: Xcode's xccov reports only
# coveredLines/executableLines/lineCoverage (no statement/branch metrics).
#
# Every Swift source the app compiles is gated application logic. What is excluded is named
# symbol by symbol, never by directory, so moving a file cannot change whether it is measured.
# Two verdicts must both hold: Sources/Managers/ keeps its own threshold, and the whole gated
# population has one as well, so expanding the gate cannot weaken the floor it already had.
#
# The gate fails closed. A percentage is compared only once the report has been found to measure
# exactly the gated sources on disk, each carrying at least one executable line, and to carry every
# symbol the policy excludes. A report that cannot support a verdict exits 2; coverage that was
# measured and fell short exits 1.
#
# Usage:
# check-coverage.sh                   # run tests with coverage, then check
# check-coverage.sh path/to.xcresult  # check an existing result bundle
# check-coverage.sh path/to.json      # check an already-extracted xccov report
#
# The .json form is how verify-coverage-gate.py drives this policy over synthetic reports.

# Single source of truth for the threshold (percent), for both verdicts.
COVERAGE_MIN=85

cd "$(dirname "$0")"

RESULT="${1:-build/TestResults.xcresult}"
TEST_ARCH="$(uname -m)"

if [ -z "${1:-}" ]; then
  rm -rf "$RESULT"
  xcodebuild \
    -project ClipboardTTSApp.xcodeproj \
    -scheme ClipboardTTSApp \
    -destination "platform=macOS,arch=${TEST_ARCH}" \
    -enableCodeCoverage YES \
    -resultBundlePath "$RESULT" \
    test
fi

if [ ! -e "$RESULT" ]; then
  echo "error: result bundle not found: $RESULT" >&2
  exit 2
fi

# The gated population is what is on disk now, so a report that omits a source, or counts one that
# no longer exists, is refused rather than averaged.
APP_SOURCES="$(find Sources -name '*.swift' 2>/dev/null | sed 's|^Sources/||' | sort)" \
  || APP_SOURCES=""

if [ "${RESULT##*.}" = "json" ]; then
  report_json() { cat "$RESULT"; }
else
  report_json() { xcrun xccov view --report --json "$RESULT"; }
fi

# A report that could not be extracted is unmeasurable, not insufficient, so it must not reach the
# threshold comparison and exit as though coverage had been measured.
REPORT_FILE="$(mktemp)"
trap 'rm -f "$REPORT_FILE"' EXIT
if ! report_json > "$REPORT_FILE"; then
  echo "error: could not extract a coverage report from $RESULT" >&2
  exit 2
fi

COVERAGE_MIN="$COVERAGE_MIN" APP_SOURCES="$APP_SOURCES" REPORT_FILE="$REPORT_FILE" \
  /usr/bin/python3 - <<'POLICY'
import json
import os
import sys

try:
    MIN_PCT = int(os.environ["COVERAGE_MIN"])
except ValueError:
    MIN_PCT = None
APP_SOURCES = {name for name in os.environ["APP_SOURCES"].split("\n") if name}
APP_TARGET = "ClipboardTTSApp.app"
GATED_GROUP = "Managers/"

# Sources that compile to no executable lines, so no coverage record names them. One that gains
# executable lines is application logic and must be removed from here rather than left unmeasured.
SOURCES_WITHOUT_EXECUTABLE_LINES = {
    "SettingsKeys.swift": "declares only UserDefaults key names",
}

# Platform adapters excluded from both sides of the ratio, named by the symbol that owns the lines.
# A symbol matches by substring, so the closures the compiler emits inside it are excluded with it.
# Each entry must match at least one record in its own source, so a rename fails the gate instead of
# silently emptying or widening an exclusion. README owns the smoke check each one carries.
EXCLUDED_SYMBOLS = (
    (
        "Views/MenuAlertPresenter.swift",
        "AppKitMenuAlertPresenter.presentAlert(title:message:)",
        "activates the app and runs a modal NSAlert that no test could dismiss",
    ),
    (
        "AboutAction.swift",
        "StandardAboutPanelPresenter.showAbout(applicationName:applicationVersion:)",
        "orders AppKit's standard About panel to the front",
    ),
    (
        "SecretStore.swift",
        "KeychainSecretStore.secret(for:)",
        "reads the developer's real Keychain",
    ),
    (
        "SecretStore.swift",
        "KeychainSecretStore.saveSecret(_:for:)",
        "writes the developer's real Keychain",
    ),
    (
        "SecretStore.swift",
        "KeychainSecretStore.deleteSecret(for:)",
        "deletes from the developer's real Keychain",
    ),
    (
        "SecretStore.swift",
        "KeychainSecretStore.itemQuery(for:)",
        "builds the query those Keychain calls issue",
    ),
)


def unmeasurable(message):
    """Refuse to report a verdict the report cannot support. Never the threshold exit code."""
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def counts(record, description):
    """The two line counts of a file or function record, or a refusal.

    Counts a report cannot mean — a boolean, a negative, or more covered lines than executable ones
    — are refused here rather than averaged into a percentage.
    """
    covered = record.get("coveredLines")
    executable = record.get("executableLines")
    for count in (covered, executable):
        if isinstance(count, bool) or not isinstance(count, int):
            unmeasurable(f"coverage report record for {description} is missing a line count")
    if not 0 <= covered <= executable:
        unmeasurable(
            f"coverage report record for {description} counts "
            f"{covered} of {executable} executable lines"
        )
    return covered, executable


def relative(path):
    """A record's name relative to Sources/.

    Read from the last /Sources/ component, so a checkout living under a directory that is itself
    named Sources still names its files the way the population on disk does.
    """
    return path.rsplit("/Sources/", 1)[-1] if "/Sources/" in path else path


if MIN_PCT is None:
    unmeasurable("the coverage threshold is not a whole percent")

if not APP_SOURCES:
    unmeasurable("no sources found under Sources/")

try:
    with open(os.environ["REPORT_FILE"]) as handle:
        report = json.load(handle)
except (OSError, ValueError) as error:
    unmeasurable(f"coverage report is not valid JSON: {error}")

targets = report.get("targets") if isinstance(report, dict) else None
if not isinstance(targets, list):
    unmeasurable("coverage report declares no targets")

target = next(
    (t for t in targets if isinstance(t, dict) and t.get("name") == APP_TARGET), None
)
if target is None:
    unmeasurable(f"{APP_TARGET} target not found in coverage report")
if not isinstance(target.get("files"), list):
    unmeasurable(f"{APP_TARGET} target declares no files")

measured = {}
for record in target["files"]:
    if not isinstance(record, dict):
        unmeasurable("coverage report contains a file record that is not an object")
    path = record.get("path")
    if not isinstance(path, str):
        unmeasurable("coverage report contains a file record without a path")
    name = relative(path)
    if name in measured:
        unmeasurable(f"coverage report counts {name} more than once")
    covered, executable = counts(record, path)
    measured[name] = {
        "covered": covered,
        "executable": executable,
        "functions": record.get("functions"),
        "excluded": (0, 0),
    }

expected = APP_SOURCES - set(SOURCES_WITHOUT_EXECUTABLE_LINES)
absent = sorted(expected - set(measured))
if absent:
    unmeasurable("gated sources missing from the coverage report: " + ", ".join(absent))
stale = sorted(set(measured) - APP_SOURCES)
if stale:
    unmeasurable("coverage report counts sources that are not on disk: " + ", ".join(stale))
unlisted = sorted(set(SOURCES_WITHOUT_EXECUTABLE_LINES) - APP_SOURCES)
if unlisted:
    unmeasurable("sources listed as carrying no executable lines are not on disk: " + ", ".join(unlisted))
carrying_lines = sorted(
    name
    for name in SOURCES_WITHOUT_EXECUTABLE_LINES
    if name in measured and measured[name]["executable"] > 0
)
if carrying_lines:
    unmeasurable(
        "sources listed as carrying no executable lines now carry them: " + ", ".join(carrying_lines)
    )
unmeasured = sorted(name for name in expected if measured[name]["executable"] == 0)
if unmeasured:
    unmeasurable("gated sources report no executable lines: " + ", ".join(unmeasured))

# Subtracting a symbol's lines is only exact if the source's functions account for exactly what the
# source reports. A function that overstates its lines would otherwise subtract uncovered lines the
# file never carried, and lift the ratio above what was measured.
for source in sorted({source for source, _symbol, _rationale in EXCLUDED_SYMBOLS}):
    if source not in measured:
        unmeasurable(f"excluded symbol names a source the report does not measure: {source}")
    functions = measured[source]["functions"]
    if not isinstance(functions, list):
        unmeasurable(f"coverage report record for {source} declares no functions")
    covered = executable = 0
    for function in functions:
        if not isinstance(function, dict) or not isinstance(function.get("name"), str):
            unmeasurable(f"coverage report record for {source} has an unreadable function record")
        function_covered, function_executable = counts(function, f"{function['name']} in {source}")
        covered += function_covered
        executable += function_executable
    if (covered, executable) != (measured[source]["covered"], measured[source]["executable"]):
        unmeasurable(
            f"coverage report functions for {source} sum to {covered}/{executable}, not the "
            f"{measured[source]['covered']}/{measured[source]['executable']} the source reports"
        )

claimed = set()
for source, symbol, _rationale in EXCLUDED_SYMBOLS:
    matches = [f for f in measured[source]["functions"] if symbol in f["name"]]
    if not matches:
        unmeasurable(f"excluded symbol matches nothing in {source}: {symbol}")
    covered, executable = measured[source]["excluded"]
    for function in matches:
        if (source, function["name"]) in claimed:
            unmeasurable(f"two exclusions cover {function['name']} in {source}")
        claimed.add((source, function["name"]))
        covered += function["coveredLines"]
        executable += function["executableLines"]
    measured[source]["excluded"] = (covered, executable)

for name, record in measured.items():
    # What remains is exactly the functions no exclusion claimed, because the sums above account for
    # every line the source reports.
    record["gated"] = (
        record["covered"] - record["excluded"][0],
        record["executable"] - record["excluded"][1],
    )


def pct(covered, executable):
    """The measured percentage to two places, truncated, in exact integer arithmetic.

    A population with no executable lines has no percentage: reading it as 100% is what let a
    report measuring nothing pass this gate. Counts never become binary floating point, which
    would round a ratio below the threshold up onto it and overflow on a large enough report.
    """
    if executable == 0:
        return "n/a"
    hundredths = covered * 10000 // executable
    return f"{hundredths // 100}.{hundredths % 100:02d}%"


def show(title, names):
    members = sorted(names)
    cov = sum(measured[name]["gated"][0] for name in members)
    ex = sum(measured[name]["gated"][1] for name in members)
    print(f"\n{title} ({pct(cov, ex)}, {cov}/{ex}):")
    for name in members:
        print(f"  {pct(*measured[name]['gated']):>7}  Sources/{name}")
    return cov, ex


gated_names = [name for name in measured if measured[name]["gated"][1] > 0]
managers = [name for name in gated_names if name.startswith(GATED_GROUP)]
others = [name for name in gated_names if not name.startswith(GATED_GROUP)]
if not managers:
    unmeasurable(f"no gated sources with executable lines under Sources/{GATED_GROUP}")

print("=== Line coverage (app target) ===")
m_cov, m_ex = show("Managers  [own %d%% floor]" % MIN_PCT, managers)
o_cov, o_ex = show("Elsewhere [no floor of its own]", others)

excluded_lines = sum(record["excluded"][1] for record in measured.values())
print(f"\nExcluded platform symbols ({excluded_lines} executable lines):")
for source, symbol, rationale in EXCLUDED_SYMBOLS:
    print(f"  Sources/{source}  {symbol}\n      {rationale}")
print()

failed = False
for title, cov, ex in (
    ("Managers", m_cov, m_ex),
    ("application-logic", m_cov + o_cov, m_ex + o_ex),
):
    # Exactly, rather than nearly: a ratio below the threshold fails however close it is, and one
    # that reaches it passes.
    verdict = "FAIL" if cov * 100 < MIN_PCT * ex else "PASS"
    reached = "is below" if verdict == "FAIL" else "meets"
    print(f"{verdict}: {title} line coverage {pct(cov, ex)} {reached} the {MIN_PCT}% threshold.")
    failed = failed or verdict == "FAIL"
if failed:
    sys.exit(1)
POLICY
