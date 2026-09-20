#!/usr/bin/env python3
"""Verify check-coverage.sh's fail-closed policy against synthetic xccov reports.

Run this whenever that policy changes. It needs no build, no result bundle, and no network: it
drives the real gate end to end through its .json report form, so what it verifies is the script
the gate actually runs. The gated population still comes from the sources on disk, which is why
the fixtures name the repository's own sources rather than invented ones.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent
GATE = REPO / "check-coverage.sh"

# Ordinary readings, chosen to clear the 85% threshold on both verdicts.
BASE_COVERED = 95
BASE_EXECUTABLE = 100

# What the policy excludes, as the report presents it: the symbol that owns the lines, the closures
# the compiler emits inside it, and how many executable lines each carries.
EXCLUDED_FUNCTIONS = {
    "Views/MenuAlertPresenter.swift": (
        ("AppKitMenuAlertPresenter.presentAlert(title:message:)", 10),
    ),
    "AboutAction.swift": (
        ("StandardAboutPanelPresenter.showAbout(applicationName:applicationVersion:)", 14),
        ("closure #1 in StandardAboutPanelPresenter.showAbout(applicationName:applicationVersion:)", 5),
    ),
    "SecretStore.swift": (
        ("KeychainSecretStore.secret(for:)", 16),
        ("KeychainSecretStore.saveSecret(_:for:)", 17),
        ("KeychainSecretStore.deleteSecret(for:)", 6),
        ("implicit closure #1 in KeychainSecretStore.deleteSecret(for:)", 1),
        ("KeychainSecretStore.itemQuery(for:)", 7),
    ),
}

# The policy lists this source as compiling to no executable lines, so no record names it.
SOURCE_WITHOUT_LINES = "SettingsKeys.swift"


def sources(root=REPO):
    """Every Swift source on disk under root/Sources, named the way the policy names it."""
    found = sorted(str(p.relative_to(root / "Sources")) for p in (root / "Sources").rglob("*.swift"))
    assert found, f"expected Swift sources under {root}/Sources"
    return [name for name in found if name != SOURCE_WITHOUT_LINES]


def function(name, covered, executable):
    return {"name": name, "lineNumber": 1, "coveredLines": covered, "executableLines": executable}


def record(name, covered, executable, prefix):
    """One file record, carrying the excluded symbols of that source as uncovered functions."""
    excluded = EXCLUDED_FUNCTIONS.get(name, ())
    entry = {
        "path": str(Path(prefix) / "Sources" / name),
        "name": Path(name).name,
        "coveredLines": covered,
        "executableLines": executable + sum(lines for _, lines in excluded),
        "lineCoverage": covered / executable if executable else 0.0,
    }
    if excluded:
        # A real record also carries the functions that are not excluded, and its functions account
        # for exactly what the source reports; the policy checks that before it subtracts anything.
        entry["functions"] = [function(symbol, 0, lines) for symbol, lines in excluded] + [
            function(f"{Path(name).stem}.measuredWork()", covered, executable)
        ]
    return entry


class Draft:
    """A report under construction, which one mutation shapes into the case being verified."""

    def __init__(self, prefix=REPO, names=None):
        self.prefix = prefix
        self.names = names if names is not None else sources()
        self.records = {
            name: record(name, BASE_COVERED, BASE_EXECUTABLE, prefix) for name in self.names
        }
        self.extra = []
        self.target_name = "ClipboardTTSApp.app"
        self.files = None
        self.report = None

    def add(self, name, covered, executable):
        self.extra.append(record(name, covered, executable, self.prefix))

    def set_counts(self, predicate, covered, executable):
        for name in self.names:
            if predicate(name):
                self.records[name] = record(name, covered, executable, self.prefix)

    def build(self):
        if self.report is not None:
            return self.report
        files = list(self.records.values()) + self.extra if self.files is None else self.files
        return {
            "targets": [
                {"name": self.target_name, "files": files},
                {"name": "ClipboardTTSAppTests.xctest", "files": []},
            ]
        }


def is_manager(name):
    return name.startswith("Managers/")


def mutate_below_threshold(draft):
    draft.set_counts(lambda name: True, 50, BASE_EXECUTABLE)


def mutate_managers_below_floor(draft):
    # Managers alone under the floor, with everything else high enough that the whole population
    # still clears it: the two verdicts must disagree.
    draft.set_counts(is_manager, 84, BASE_EXECUTABLE)
    draft.set_counts(lambda name: not is_manager(name), BASE_EXECUTABLE, BASE_EXECUTABLE)


def mutate_elsewhere_below_whole(draft):
    draft.set_counts(is_manager, BASE_EXECUTABLE, BASE_EXECUTABLE)
    draft.set_counts(lambda name: not is_manager(name), 0, BASE_EXECUTABLE)


def mutate_just_below_the_threshold(draft):
    # 84.9999999999999999%, which binary floating point rounds onto the threshold exactly.
    draft.set_counts(lambda name: True, 849999999999999999, 10**18)


def mutate_counts_beyond_floating_point(draft):
    # Exactly the threshold, in counts too large to turn into a float at all.
    draft.set_counts(lambda name: True, 85 * 10**307, 100 * 10**307)


def mutate_gated_source_absent(draft):
    del draft.records["Views/SettingsView.swift"]


def mutate_manager_absent(draft):
    del draft.records["Managers/CallbackAuthority.swift"]


def mutate_stale_source(draft):
    draft.add("Views/RemovedView.swift", BASE_COVERED, BASE_EXECUTABLE)


def mutate_duplicate_source(draft):
    draft.add("Views/SettingsView.swift", BASE_EXECUTABLE, BASE_EXECUTABLE)


def mutate_source_without_executable_lines(draft):
    draft.records["Views/SettingsView.swift"] = record("Views/SettingsView.swift", 0, 0, draft.prefix)


def mutate_listed_source_present_empty(draft):
    draft.add(SOURCE_WITHOUT_LINES, 0, 0)


def mutate_listed_source_carries_lines(draft):
    draft.add(SOURCE_WITHOUT_LINES, BASE_COVERED, BASE_EXECUTABLE)


def mutate_excluded_symbol_renamed(draft):
    entry = draft.records["SecretStore.swift"]
    for fn in entry["functions"]:
        if fn["name"] == "KeychainSecretStore.itemQuery(for:)":
            fn["name"] = "KeychainSecretStore.renamedItemQuery(for:)"


def mutate_exclusion_source_without_functions(draft):
    del draft.records["SecretStore.swift"]["functions"]


def mutate_unreadable_function_record(draft):
    draft.records["SecretStore.swift"]["functions"].append("KeychainSecretStore.itemQuery(for:)")


def mutate_functions_disagree_with_the_file(draft):
    entry = draft.records["SecretStore.swift"]
    entry["coveredLines"] = 5
    entry["executableLines"] = 10


def mutate_functions_omit_part_of_the_source(draft):
    # Function records that account for only part of what the source reports leave the rest
    # unattributed, so the remainder after subtraction would not be what it claims to be.
    entry = draft.records["SecretStore.swift"]
    entry["functions"] = [fn for fn in entry["functions"] if not fn["name"].endswith(".measuredWork()")]


def mutate_overstated_excluded_symbol(draft):
    # An excluded symbol claiming more uncovered lines than its source attributes to it would
    # subtract lines the file never carried, and lift the ratio above what was measured.
    for fn in draft.records["SecretStore.swift"]["functions"]:
        if fn["name"] == "KeychainSecretStore.itemQuery(for:)":
            fn["executableLines"] += 5


def mutate_one_function_two_exclusions(draft):
    entry = draft.records["SecretStore.swift"]
    entry["functions"].append(
        function("KeychainSecretStore.secret(for:) via KeychainSecretStore.itemQuery(for:)", 0, 3)
    )
    entry["executableLines"] += 3


def mutate_partially_covered_exclusion(draft):
    # The same source total, with 16 of its covered lines belonging to an excluded symbol.
    for fn in draft.records["SecretStore.swift"]["functions"]:
        if fn["name"] == "KeychainSecretStore.secret(for:)":
            fn["coveredLines"] = fn["executableLines"]
        elif fn["name"].endswith(".measuredWork()"):
            fn["coveredLines"] -= 16


def mutate_fully_and_zero_covered(draft):
    draft.set_counts(lambda name: True, BASE_EXECUTABLE, BASE_EXECUTABLE)
    draft.records["Views/MenuBarView.swift"] = record("Views/MenuBarView.swift", 0, 100, draft.prefix)


def mutate_exclusion_carries_the_verdict(draft):
    # Just above the threshold once the excluded lines leave both sides, and just below it if they
    # are counted: only the subtraction decides this report.
    draft.set_counts(lambda name: True, 86, BASE_EXECUTABLE)


def mutate_irrelevant_function_records(draft):
    # An unexcluded source's function records are never read, so records that do not account for
    # what that source reports are an ordinary input rather than a reason to refuse the report.
    draft.records["Views/SettingsView.swift"]["functions"] = [
        function("SettingsView.body.getter", 3, 7),
    ]


def mutate_symbol_name_reused_elsewhere(draft):
    # An excluded symbol's name appearing in another source excludes nothing there: an exclusion is
    # bound to the source it names.
    draft.records["Views/MenuBarView.swift"]["functions"] = [
        function("KeychainSecretStore.itemQuery(for:)", 0, 5),
        function("MenuBarView.body.getter", 95, 95),
    ]


def mutate_minimal_record(draft):
    entry = draft.records["Views/SettingsView.swift"]
    draft.records["Views/SettingsView.swift"] = {
        key: entry[key] for key in ("path", "coveredLines", "executableLines")
    }


def mutate_missing_target(draft):
    draft.target_name = "SomeOtherApp.app"


def mutate_no_targets(draft):
    draft.report = {"unexpected": []}


def mutate_files_not_a_list(draft):
    draft.files = None
    draft.report = {"targets": [{"name": draft.target_name, "files": None}]}


def mutate_record_not_an_object(draft):
    draft.records["Views/SettingsView.swift"] = "Sources/Views/SettingsView.swift"


def mutate_record_without_path(draft):
    del draft.records["Views/SettingsView.swift"]["path"]


def mutate_record_without_count(draft):
    del draft.records["Views/SettingsView.swift"]["executableLines"]


def mutate_negative_counts(draft):
    entry = draft.records["Views/SettingsView.swift"]
    entry["coveredLines"] = -1
    entry["executableLines"] = -1


def mutate_boolean_counts(draft):
    entry = draft.records["Views/SettingsView.swift"]
    entry["coveredLines"] = True
    entry["executableLines"] = True


def mutate_covered_exceeds_executable(draft):
    entry = draft.records["Views/SettingsView.swift"]
    entry["coveredLines"] = 101
    entry["executableLines"] = 100


MUTATIONS = {
    "valid": lambda draft: None,
    "below-threshold": mutate_below_threshold,
    "managers-below-floor": mutate_managers_below_floor,
    "elsewhere-below-whole": mutate_elsewhere_below_whole,
    "just-below-the-threshold": mutate_just_below_the_threshold,
    "counts-beyond-floating-point": mutate_counts_beyond_floating_point,
    "gated-source-absent": mutate_gated_source_absent,
    "manager-absent": mutate_manager_absent,
    "stale-source": mutate_stale_source,
    "duplicate-source": mutate_duplicate_source,
    "source-without-executable-lines": mutate_source_without_executable_lines,
    "listed-source-present-empty": mutate_listed_source_present_empty,
    "listed-source-carries-lines": mutate_listed_source_carries_lines,
    "excluded-symbol-renamed": mutate_excluded_symbol_renamed,
    "exclusion-source-without-functions": mutate_exclusion_source_without_functions,
    "unreadable-function-record": mutate_unreadable_function_record,
    "functions-disagree-with-the-file": mutate_functions_disagree_with_the_file,
    "overstated-excluded-symbol": mutate_overstated_excluded_symbol,
    "functions-omit-part-of-the-source": mutate_functions_omit_part_of_the_source,
    "one-function-two-exclusions": mutate_one_function_two_exclusions,
    "partially-covered-exclusion": mutate_partially_covered_exclusion,
    "fully-and-zero-covered": mutate_fully_and_zero_covered,
    "exclusion-carries-the-verdict": mutate_exclusion_carries_the_verdict,
    "irrelevant-function-records": mutate_irrelevant_function_records,
    "symbol-name-reused-elsewhere": mutate_symbol_name_reused_elsewhere,
    "minimal-record": mutate_minimal_record,
    "missing-target": mutate_missing_target,
    "no-targets": mutate_no_targets,
    "files-not-a-list": mutate_files_not_a_list,
    "record-not-an-object": mutate_record_not_an_object,
    "record-without-path": mutate_record_without_path,
    "record-without-count": mutate_record_without_count,
    "negative-counts": mutate_negative_counts,
    "boolean-counts": mutate_boolean_counts,
    "covered-exceeds-executable": mutate_covered_exceeds_executable,
}


class Verification:
    """Runs the real gate over each fixture and accounts for the cases that did not hold."""

    def __init__(self, work):
        self.work = work
        self.failures = []

    def fixture(self, label, mode, prefix=REPO, names=None):
        draft = Draft(prefix=prefix, names=names)
        MUTATIONS[mode](draft)
        path = self.work / f"{label}.json"
        path.write_text(json.dumps(draft.build(), default=str))
        return path

    def run(self, fixture, script=GATE):
        return subprocess.run(
            [str(script), str(fixture)], capture_output=True, text=True, cwd=str(REPO)
        )

    def report(self, label, proc, status, out_needles, err_needles, forbidden):
        problems = []
        if proc.returncode != status:
            problems.append(f"wanted exit {status}, got {proc.returncode}")
        for needle in out_needles:
            if needle not in proc.stdout:
                problems.append(f"stdout is missing {needle!r}")
        for needle in err_needles:
            if needle not in proc.stderr:
                problems.append(f"stderr is missing {needle!r}")
        for needle in forbidden:
            # Neither stream may carry a verdict a refusal did not reach, not just the one the
            # verdicts are printed on.
            for stream, text in (("stdout", proc.stdout), ("stderr", proc.stderr)):
                if needle in text:
                    problems.append(f"{stream} should not contain {needle!r}")
        if not err_needles and proc.stderr:
            problems.append(f"stderr should be empty, got {proc.stderr.strip()!r}")
        if problems:
            self.failures.append(label)
            print(f"FAIL {label}: " + "; ".join(problems))
            print(f"     stdout: {proc.stdout.strip()[-400:]}")
            print(f"     stderr: {proc.stderr.strip()[-400:]}")
        else:
            print(f"ok   {label} (exit {proc.returncode})")

    def passes(self, label, mode, *needles, **kwargs):
        """A measured report that clears both thresholds, on stdout, with nothing on stderr."""
        proc = self.run(self.fixture(label, mode, **kwargs))
        self.report(label, proc, 0, needles, (), ("FAIL:",))

    def falls_short(self, label, mode, *needles):
        """Coverage that was measured and fell short: exit 1, and the verdicts say which."""
        proc = self.run(self.fixture(label, mode))
        self.report(label, proc, 1, needles, (), ())

    def refuses(self, label, mode, needle, **kwargs):
        """A report that cannot support a verdict: exit 2 on stderr, and no verdict printed."""
        proc = self.run(self.fixture(label, mode, **kwargs))
        self.report(label, proc, 2, (), (needle,), ("PASS:", "FAIL:"))

    def refuses_path(self, label, fixture, needle, script=GATE):
        proc = self.run(fixture, script=script)
        self.report(label, proc, 2, (), (needle,), ("PASS:", "FAIL:"))


def main():
    with tempfile.TemporaryDirectory() as raw:
        work = Path(raw)
        v = Verification(work)

        # A measured report still decides on its measured coverage, and both verdicts are reported.
        v.passes(
            "measured-report-passes",
            "valid",
            "PASS: Managers line coverage",
            "PASS: application-logic line coverage",
            "Excluded platform symbols (76 executable lines)",
        )
        v.falls_short(
            "measured-report-below-threshold-fails",
            "below-threshold",
            "FAIL: Managers line coverage",
            "FAIL: application-logic line coverage",
        )

        # The comparison is exact: a ratio below the threshold fails however close it is, one that
        # reaches it passes, and neither the verdict nor the percentage becomes a float on the way.
        v.falls_short(
            "a-ratio-just-below-the-threshold-still-fails",
            "just-below-the-threshold",
            "FAIL: Managers line coverage 84.99%",
            "FAIL: application-logic line coverage 84.99%",
        )
        v.passes(
            "counts-too-large-for-floating-point",
            "counts-beyond-floating-point",
            "PASS: Managers line coverage 85.00%",
            "PASS: application-logic line coverage 85.00%",
        )

        # The two verdicts are independent: expanding the gate did not dissolve the Managers floor,
        # and the floor does not stand in for the whole population either.
        v.falls_short(
            "managers-below-its-own-floor",
            "managers-below-floor",
            "FAIL: Managers line coverage",
            "PASS: application-logic line coverage",
        )
        v.falls_short(
            "logic-outside-managers-drags-the-whole-down",
            "elsewhere-below-whole",
            "PASS: Managers line coverage",
            "FAIL: application-logic line coverage",
        )

        # The verdict is computed over exactly the sources on disk, wherever they live.
        v.refuses(
            "source-outside-managers-absent",
            "gated-source-absent",
            "gated sources missing from the coverage report: Views/SettingsView.swift",
        )
        v.refuses(
            "manager-absent",
            "manager-absent",
            "gated sources missing from the coverage report: Managers/CallbackAuthority.swift",
        )
        v.refuses(
            "stale-source-not-counted",
            "stale-source",
            "coverage report counts sources that are not on disk: Views/RemovedView.swift",
        )
        v.refuses(
            "source-counted-twice",
            "duplicate-source",
            "coverage report counts Views/SettingsView.swift more than once",
        )
        v.refuses(
            "gated-source-without-executable-lines",
            "source-without-executable-lines",
            "gated sources report no executable lines: Views/SettingsView.swift",
        )

        # A source listed as carrying no executable lines must go on carrying none.
        v.passes("listed-source-may-be-reported-empty", "listed-source-present-empty", "PASS:")
        v.refuses(
            "listed-source-that-gains-lines",
            "listed-source-carries-lines",
            "sources listed as carrying no executable lines now carry them: SettingsKeys.swift",
        )

        # An exclusion must still name something, and only its own lines.
        v.refuses(
            "excluded-symbol-matches-nothing",
            "excluded-symbol-renamed",
            "excluded symbol matches nothing in SecretStore.swift: "
            "KeychainSecretStore.itemQuery(for:)",
        )
        v.refuses(
            "exclusion-source-without-function-records",
            "exclusion-source-without-functions",
            "coverage report record for SecretStore.swift declares no functions",
        )
        v.refuses(
            "unreadable-function-record",
            "unreadable-function-record",
            "coverage report record for SecretStore.swift has an unreadable function record",
        )
        v.refuses(
            "functions-that-do-not-sum-to-their-source",
            "functions-disagree-with-the-file",
            "coverage report functions for SecretStore.swift sum to",
        )
        v.refuses(
            "functions-that-account-for-only-part-of-their-source",
            "functions-omit-part-of-the-source",
            "coverage report functions for SecretStore.swift sum to 0/47, not the 95/147",
        )
        v.refuses(
            "excluded-symbol-claiming-lines-its-source-does-not-carry",
            "overstated-excluded-symbol",
            "coverage report functions for SecretStore.swift sum to 95/152, not the 95/147",
        )
        v.refuses(
            "one-function-claimed-by-two-exclusions",
            "one-function-two-exclusions",
            "two exclusions cover",
        )

        # A report the gate cannot read is unmeasurable, never insufficient: none of these exit 1.
        v.refuses("missing-target", "missing-target", "ClipboardTTSApp.app target not found")
        v.refuses("report-without-targets", "no-targets", "coverage report declares no targets")
        v.refuses("target-files-not-a-list", "files-not-a-list", "declares no files")
        v.refuses(
            "record-that-is-not-an-object",
            "record-not-an-object",
            "file record that is not an object",
        )
        v.refuses("record-without-a-path", "record-without-path", "file record without a path")
        v.refuses("record-without-a-line-count", "record-without-count", "is missing a line count")
        v.refuses("negative-line-counts", "negative-counts", "counts -1 of -1 executable lines")
        v.refuses("boolean-line-counts", "boolean-counts", "is missing a line count")
        v.refuses(
            "covered-exceeds-executable",
            "covered-exceeds-executable",
            "counts 101 of 100 executable lines",
        )

        malformed = work / "malformed.json"
        malformed.write_text("{ this is not json")
        v.refuses_path("malformed-report", malformed, "coverage report is not valid JSON")

        unreadable = work / "not-a-bundle.xcresult"
        unreadable.mkdir()
        v.refuses_path(
            "unreadable-result-bundle", unreadable, "could not extract a coverage report"
        )
        v.refuses_path("absent-report", work / "never-written.json", "not found")

        # The excluded lines leave both sides of the ratio, and only in the source that names them.
        v.passes(
            "excluded-lines-decide-a-borderline-report",
            "exclusion-carries-the-verdict",
            "PASS: application-logic line coverage 86.00%",
        )
        v.passes(
            "an-excluded-name-reused-elsewhere-excludes-nothing",
            "symbol-name-reused-elsewhere",
            "Excluded platform symbols (76 executable lines)",
            "PASS: application-logic line coverage",
        )

        # None of that tightens what an ordinary record may look like: the function records of a
        # source no exclusion names are never read, so they need not account for anything.
        v.passes(
            "function-records-of-an-unexcluded-source-are-not-read",
            "irrelevant-function-records",
            "PASS: application-logic line coverage",
        )
        v.passes("record-with-minimal-fields-passes", "minimal-record", "PASS:")
        # SecretStore.swift reports 95 covered of 147, of which the excluded symbols carry 16 of
        # 47: both counts leave the ratio, so what remains is 79 of 100 rather than 95 of 100.
        v.passes(
            "a-covered-excluded-symbol-leaves-both-counts",
            "partially-covered-exclusion",
            "79.00%  Sources/SecretStore.swift",
            "PASS:",
        )
        v.passes(
            "fully-and-zero-covered-counts-pass",
            "fully-and-zero-covered",
            "PASS: Managers line coverage 100.00%",
        )

        # A checkout under a directory named Sources names its sources the same way.
        v.passes(
            "checkout-under-a-sources-parent",
            "valid",
            "PASS: application-logic line coverage",
            prefix=Path("/private/tmp/Sources/Checkout"),
        )

        # A gate run where there is nothing to measure says so rather than dividing by an empty
        # population, whether the whole tree or only the floor's own directory is missing.
        bare = work / "no-sources"
        bare.mkdir()
        shutil.copy(GATE, bare / GATE.name)
        v.refuses_path(
            "no-sources-on-disk",
            v.fixture("no-sources-fixture", "valid"),
            "no sources found under Sources/",
            script=bare / GATE.name,
        )

        without_managers = work / "no-managers"
        without_managers.mkdir()
        shutil.copy(GATE, without_managers / GATE.name)
        shutil.copytree(
            REPO / "Sources",
            without_managers / "Sources",
            ignore=shutil.ignore_patterns("Managers"),
        )
        v.refuses_path(
            "no-managers-on-disk",
            v.fixture(
                "no-managers-fixture",
                "valid",
                prefix=without_managers,
                names=sources(without_managers),
            ),
            "no gated sources with executable lines under Sources/Managers/",
            script=without_managers / GATE.name,
        )

        without_listed_source = work / "no-listed-source"
        without_listed_source.mkdir()
        shutil.copy(GATE, without_listed_source / GATE.name)
        shutil.copytree(
            REPO / "Sources",
            without_listed_source / "Sources",
            ignore=shutil.ignore_patterns(SOURCE_WITHOUT_LINES),
        )
        v.refuses_path(
            "listed-source-no-longer-on-disk",
            v.fixture(
                "listed-source-gone-fixture",
                "valid",
                prefix=without_listed_source,
                names=sources(without_listed_source),
            ),
            f"sources listed as carrying no executable lines are not on disk: {SOURCE_WITHOUT_LINES}",
            script=without_listed_source / GATE.name,
        )

    print()
    if v.failures:
        print(f"FAIL: {len(v.failures)} coverage-gate verification case(s) failed: "
              + ", ".join(v.failures))
        return 1
    print("PASS: every coverage-gate verification case held.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
