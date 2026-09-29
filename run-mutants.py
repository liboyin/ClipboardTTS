#!/usr/bin/env python3
"""Runs mutation evidence for this repository in an isolated scratch copy.

A spec names mutants as exact text replacements. The runner builds one scratch copy of the
current target state, runs an unmutated control, then applies each mutant in turn, runs the
selected tests, restores the copy, and classifies the run from its log by the failing tests it
names. Exit codes and XCTest's summary lines are not verdicts: a mutant that fails to compile
also exits non-zero, and an over-fulfilled expectation aborts the runner with "Executed 0
tests" after an assertion has already failed.

Spec (JSON):
    {
      "tests": ["ClipboardTTSAppTests/SomeSuite"],
      "untracked": ["Tests/NewFile.swift"],
      "mutants": [
        {"name": "revert-guard",
         "edits": [{"path": "Sources/X.swift", "old": "exact text", "new": "replacement"}]}
      ]
    }

The tests and untracked lists are optional; tests defaults to the whole bundle.

Usage:
    run-mutants.py SPEC.json --out DIR [--only NAME ...] [--test-deadline SECONDS]

DIR must lie outside the repository, must not contain it, and must be new, empty, or one this
runner created. The copy, derived data, per-mutant logs, and a results.json are written there, and
the copy stays for inspection. results.json records whether the run completed, its exit code,
HEAD, digests of the spec and of the copied target state, the deadlines it ran under, the control's
verdict, and each finished mutant's result, an unjudged one included; a run refused before its
control writes none. Exit 0 means every mutant received a verdict, whatever it was; 1 means a mutant
got no verdict, from a run cut short or a failure naming no test, or ran no test for some selector, or
that the runner raised an exception it does not expect, which ends it with a traceback; 2 means the
runner refused the run or was interrupted by SIGINT or SIGTERM once the control began.
Either signal before then ends the runner by that signal, before any mutant is applied; any other
signal, such as SIGHUP, ends it at once and can leave the copy mutated until the next run rebuilds
it. A test run, build included, still going after --test-deadline seconds (default 1800) is stopped
and gets no verdict, and the next mutant runs; XcodeGen or uname still going after 60 seconds is
killed and stops the run with exit 2.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

TERMINAL_MARKERS = ("** TEST SUCCEEDED **", "** TEST FAILED **")
BUILD_FAILURE_MARKERS = ("** BUILD FAILED **", "Testing cancelled because the build failed",
                         "The following build commands failed:")
NAMED_FAILURE = re.compile(r"error: -\[([^\s\]]+) ([^\s\]]+)\]")
# Xcode 27 ends a failed run's log with this heading, one tab-indented "Suite.test()" line per failing test,
# which omits the module, and a blank line above the final marker. It lists a test that crashed, exited, or
# exceeded an enabled execution allowance, which no "error: -[…]" line names.
SUMMARY_HEADING = "Failing tests:"
SUMMARY_ENTRY = re.compile(r"\t(\S+)\.([^.\s]+)\(\)")
# Xcode 27 writes "Executed 3 tests, with 2 tests skipped and 0 failures" when any test skipped; the
# executed count includes the skipped ones.
EXECUTED = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?\d+ failures?")
STARTED = re.compile(r"^Test Case '-\[([^.\s\]]+)\.([^\s\]]+) ([^\s\]]+)\]' started\.$", re.MULTILINE)
SKIPPED = re.compile(r"^Test Case '-\[([^.\s\]]+)\.([^\s\]]+) ([^\s\]]+)\]' skipped \(", re.MULTILINE)
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
OWNERSHIP_MARKER = ".run-mutants-owned"
OWNED_CHILDREN = ("copy", "derived-data", "logs", "results.json")
# A full-bundle test run, build included, took about 50 s from fresh derived data on 2026-09-26 (Xcode
# 27.0), but a mutant that lets the tests' explicit waits expire, about 577 s if every one did, still ends
# in a named kill; a run that outlasts all of that is presumed hung.
TEST_DEADLINE = 1800
# XcodeGen generates this project in about 30 ms, and uname answers at once.
TOOL_DEADLINE = 60
# communicate() waits for a short tool in poll(), whose timeout is a C int of milliseconds, so it raises
# OverflowError past 2**31 - 1 ms, about 24.8 days; whole seconds stay below that however the time left
# rounds. A test run is waited for by wait(), which sleeps in short steps and takes any finite deadline.
TOOL_DEADLINE_LIMIT = (2**31 - 1) // 1000


class RunnerError(Exception):
    """A condition under which no verdict can be trusted."""


def classify(log):
    """Returns (verdict, details) for one xcodebuild test log.

    `KILLED` names every test a failed run reports failing, in an `error: -[…]` line or in Xcode's
    `Failing tests:` summary, which alone names a test that crashed, exited, or exceeded an enabled
    execution allowance. `SURVIVED` requires the run to have finished successfully having executed
    at least one test that was not skipped, `NO-TESTS` is a success that executed none (a selector
    that matched nothing), `BUILD-FAILED` carries the first build errors, `NO-VERDICT` covers a log
    with no terminal marker (still being written, or cut short), and `FAILED-UNNAMED` covers a
    finished failing run that names no test, such as a crash in a suite's class-level setUp or
    tearDown; like `NO-VERDICT`, it leaves a mutant unjudged.
    """
    lines = log.splitlines()
    # Only a standalone marker line counts, and the last one decides: test output can contain the
    # marker's text, and an earlier marker can precede the run's real end.
    markers = [index for index, line in enumerate(lines) if line.strip() in TERMINAL_MARKERS]
    if not markers:
        return "NO-VERDICT", []
    if lines[markers[-1]].strip() == "** TEST SUCCEEDED **":
        # A passing run's output can contain failure-shaped text; only a failed run is read for it.
        # The last summary is the whole run's; per-suite summaries precede it. Skipped tests ran nothing.
        counts = EXECUTED.findall(log)
        ran = int(counts[-1][0]) - int(counts[-1][1] or 0) if counts else 0
        return ("SURVIVED", []) if ran > 0 else ("NO-TESTS", [])
    named = {f"{suite} {test}" for suite, test in NAMED_FAILURE.findall(log)}
    named = sorted(named | summarized_failures(log, lines[:markers[-1]]))
    if named:
        return "KILLED", named
    if any(marker in log for marker in BUILD_FAILURE_MARKERS):
        errors = []
        for line in log.splitlines():
            if ": error:" in line or line.startswith("error:"):
                text = line.strip()
                if text not in errors:
                    errors.append(text)
        return "BUILD-FAILED", errors[:5]
    return "FAILED-UNNAMED", []


def summarized_failures(log, preceding):
    """Names each test listed by the `Failing tests:` summary that ends preceding, as an `error: -[…]` line would.

    preceding holds the log's lines above its final marker. Only a summary that ends them, blank
    lines aside, is the run's own: test output can print the same text, but only while tests run,
    and Xcode's own closing lines follow it. The summary omits the module, so each test takes the
    module of its own start line; a test that no start line names keeps the summary's `Suite test`.
    """
    index = len(preceding)
    while index and not preceding[index - 1].strip():
        index -= 1
    entries = []
    while index and (entry := SUMMARY_ENTRY.fullmatch(preceding[index - 1].rstrip())):
        entries.append(entry.groups())
        index -= 1
    if not index or preceding[index - 1].rstrip() != SUMMARY_HEADING:
        return set()
    modules = {}
    for module, suite, test in STARTED.findall(log):
        modules.setdefault((suite, test), set()).add(module)
    names = set()
    for suite, test in entries:
        names |= {f"{module}.{suite} {test}" for module in modules.get((suite, test), ())} or {f"{suite} {test}"}
    return names


def selectors_without_tests(log, tests):
    """Returns the selectors that no test case the log reports running, rather than skipping, belongs to.

    The run's total count cannot say this: one selector that matches tests makes it positive while
    a misspelled one beside it runs nothing. `Bundle` matches any case in the bundle, `Bundle/Suite`
    any case in that suite, and `Bundle/Suite/test` (or `test()`) that test alone.
    """
    started = set(STARTED.findall(log)) - set(SKIPPED.findall(log))

    def matches(selector, case):
        parts = selector.split("/")
        return (parts[0] == case[0] and (len(parts) < 2 or parts[1] == case[1])
                and (len(parts) < 3 or parts[2].removesuffix("()") == case[2]))

    return [selector for selector in tests if not any(matches(selector, case) for case in started)]


def positive_seconds(text):
    """Parses a deadline in seconds, refusing one that could never be met or never expire."""
    value = float(text)
    if not 0 < value < float("inf"):
        raise argparse.ArgumentTypeError(f"{text!r} is not a positive number of seconds")
    return value


def tool_seconds(text):
    """Parses a short tool's deadline, refusing one longer than communicate() can wait for."""
    value = positive_seconds(text)
    if value > TOOL_DEADLINE_LIMIT:
        raise argparse.ArgumentTypeError(f"{text!r} is longer than the {TOOL_DEADLINE_LIMIT} seconds a short tool "
                                         "can be waited for")
    return value


def relative_path(value, what):
    """Accepts only a relative path that stays below the directory it is joined to."""
    path = pathlib.PurePosixPath(value) if isinstance(value, str) and value else None
    if path is None or path.is_absolute() or ".." in path.parts:
        raise RunnerError(f"{what} must be a relative path without '..', got {value!r}")
    return value


def require_representable(value, what):
    """Refuses text no file or process argument can carry: a NUL, or a lone surrogate JSON can encode."""
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise RunnerError(f"{what} cannot be represented: it is not valid Unicode text") from None
    if "\0" in value:
        raise RunnerError(f"{what} cannot be represented: it contains a NUL character")


def reject_unknown_keys(document, allowed, what):
    """A misspelled key would otherwise be ignored and silently change what runs."""
    unknown = set(document) - allowed
    if unknown:
        raise RunnerError(f"{what} has unknown keys: {', '.join(sorted(unknown))}")


def load_spec(data):
    """Parses the spec's bytes, refusing any shape it does not document rather than failing inside the run."""
    spec = json.loads(data.decode("utf-8"))
    if not isinstance(spec, dict):
        raise RunnerError("the spec must be a JSON object")
    reject_unknown_keys(spec, {"tests", "untracked", "mutants"}, "the spec")
    for key in ("tests", "untracked"):
        value = spec.get(key, [])
        if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
            raise RunnerError(f"'{key}' must be a list of non-empty strings")
    for item in spec.get("tests", []):
        require_representable(item, "a test selector")
    for item in spec.get("untracked", []):
        require_representable(item, "an untracked path")
        relative_path(item, "an untracked path")
    mutants = spec.get("mutants")
    if not isinstance(mutants, list) or not mutants:
        raise RunnerError("the spec names no mutants")
    if not all(isinstance(m, dict) for m in mutants):
        raise RunnerError("every mutant must be a JSON object")
    for mutant in mutants:
        reject_unknown_keys(mutant, {"name", "edits"}, "a mutant")
    names = [m.get("name") for m in mutants]
    # Names become log file names, and macOS volumes usually ignore case, so neither uniqueness nor
    # the reserved control name may depend on it.
    if (any(not isinstance(n, str) or not SAFE_NAME.fullmatch(n) or n.casefold() == "control" for n in names)
            or len({n.casefold() for n in names}) != len(names)):
        raise RunnerError("every mutant needs a unique name of letters, digits, '.', '_', or '-', other than "
                          "'control', regardless of case")
    for mutant in mutants:
        edits = mutant.get("edits")
        if not isinstance(edits, list) or not edits or not all(isinstance(e, dict) for e in edits):
            raise RunnerError(f"mutant {mutant['name']} needs a list of edit objects")
        for edit in edits:
            reject_unknown_keys(edit, {"path", "old", "new"}, f"mutant {mutant['name']}'s edit")
            if (not all(isinstance(edit.get(k), str) for k in ("path", "old", "new")) or not edit["old"]
                    or edit["old"] == edit["new"]):
                raise RunnerError(f"mutant {mutant['name']} has an edit without a distinct path, old, and new text")
            for key in ("path", "old", "new"):
                require_representable(edit[key], f"mutant {mutant['name']}'s edit {key}")
            relative_path(edit["path"], f"mutant {mutant['name']}'s edit path")
    return spec


def git(repo, *args, **kwargs):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, **kwargs)


def run_shielded(command, deadline, **kwargs):
    """Runs a short tool to completion in its own session, so a terminal's signals cannot cut it short.

    A terminal's Ctrl-C signals its whole foreground process group. Inside that group the tool would
    die with the signal and could leave a regeneration half done; outside it the tool finishes, and
    only the runner hears the signal, records it, and stops once the copy is restored. The test tool
    is not started this way: it stays in the runner's group, so a terminal's signals, a hangup
    included, still end it.

    Since no terminal's signal reaches the tool, the deadline is what stops one that hangs: its whole
    session is killed, and the run stops as it does for a tool that failed.
    """
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                          **kwargs) as process:
        try:
            stdout, stderr = process.communicate(timeout=deadline)
        except subprocess.TimeoutExpired:
            emptied = kill_session(process.pid, deadline)
            process.wait()
            unconfirmed = "" if emptied else "; not every process in its session could be confirmed stopped"
            raise RunnerError(f"{' '.join(command)} did not finish within {deadline:g} seconds and was stopped"
                              f"{unconfirmed}") from None
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def kill_session(session, deadline):
    """SIGKILLs every live process in the session whose leader's id is session, returning whether none is left.

    The leader's process group dies first, so the leader can be reaped even if no listing succeeds.
    That is not enough on its own, because a member can move to a group of its own and stay in the
    session, and one can fork while the processes are listed, so listing and killing repeat until a
    listing finds none. Every listing shares the deadline, so a listing that hangs or fails, or members
    that keep appearing, end the attempt unconfirmed rather than blocking the run. The caller has not
    reaped the leader, so no other session can have taken its id; a zombie belongs to no session that
    getsid reports.
    """
    try:
        os.killpg(session, signal.SIGKILL)
    except OSError:
        pass  # nothing live is left in the leader's group
    end = time.monotonic() + deadline
    while True:
        try:
            listing = subprocess.run(["ps", "-A", "-o", "pid="], check=True, capture_output=True,
                                     timeout=max(end - time.monotonic(), 0)).stdout
        except (subprocess.SubprocessError, OSError):
            return False
        members = []
        for pid in map(int, listing.split()):
            try:
                if os.getsid(pid) == session:
                    members.append(pid)
            except OSError:
                pass  # gone since the listing, a zombie, or not this user's to inspect
        if not members:
            return True
        for pid in members:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass  # gone since it was found
        time.sleep(0.05)


def build_copy(repo, copy, untracked):
    """Copies every indexed path as the working tree holds it and the named untracked files, never ignored content.

    Nothing is generated here: edits are planned against this target state alone. Before testing,
    run_tests also checks that regeneration preserved the edit targets, including tracked outputs.
    """
    if copy.exists():
        shutil.rmtree(copy)
    copy.mkdir(parents=True)
    # One walk of the index copies clean and changed paths alike from the working tree, so neither HEAD,
    # Git's view of what changed, nor an export attribute decides what the tests see. A path no longer
    # in the index is deleted in the target state even if a file remains on disk, possibly ignored; it
    # comes back only through the named untracked files. An unmerged path is listed once per stage.
    indexed = dict.fromkeys(filter(None, git(repo, "ls-files", "--cached", "-z").stdout.decode().split("\0")))
    for path in indexed:
        # Beneath a working-tree symlink Git sees a tracked path as deleted, and following the link
        # would bring in whatever it points at instead.
        if not under_symlink(repo, path):
            mirror(repo / path, copy / path, path)
    listed = set(git(repo, "ls-files", "--others", "--exclude-standard", "-z").stdout.decode().split("\0")) - {""}
    for path in untracked:
        if path not in listed:
            raise RunnerError(f"{path} is not an untracked, unignored file in the repository")
        source = repo / path
        # Copying follows a symlink, which would bring in whatever it points at, ignored or not.
        if source.is_symlink() or not source.is_file():
            raise RunnerError(f"{path} must be a regular file, not a symlink or special file")
        (copy / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, copy / path)


def under_symlink(root, path):
    """Whether any directory between root and path is a symlink."""
    current = root
    for part in pathlib.PurePosixPath(path).parts[:-1]:
        current = current / part
        if current.is_symlink():
            return True
    return False


def mirror(source, destination, path):
    """Gives the new destination what the working tree holds at source: a file, a symlink, or nothing."""
    if source.is_symlink():
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(os.readlink(source), destination)
    elif source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    elif source.exists():
        raise RunnerError(f"{path} is in the index but is neither a file nor a symlink, such as a submodule")


def describe(error):
    """A failed tool's own message says why; CalledProcessError's text names only the exit status."""
    stderr = getattr(error, "stderr", None)
    if isinstance(stderr, bytes):
        stderr = stderr.decode(errors="replace")
    return f"{error}\n{stderr.strip()}" if stderr and stderr.strip() else str(error)


def tree_digest(root):
    """Identifies the files and symlinks below root by relative path, executable bit, and content or target."""
    total = hashlib.sha256()

    def visit(directory, prefix):
        for entry in sorted(os.scandir(directory), key=lambda entry: entry.name):
            path = os.fsencode(prefix + entry.name)
            if entry.is_symlink():
                total.update(b"L\0" + path + b"\0" + os.fsencode(os.readlink(entry.path)) + b"\0")
            elif entry.is_dir():
                visit(entry.path, prefix + entry.name + "/")
            else:
                executable = b"x" if entry.stat(follow_symlinks=False).st_mode & 0o111 else b"-"
                content = hashlib.sha256(pathlib.Path(entry.path).read_bytes()).hexdigest().encode()
                total.update(b"F\0" + path + b"\0" + executable + content + b"\0")

    visit(root, "")
    return total.hexdigest()


def digest(paths):
    return {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def confined(copy, relative):
    """Resolves a spec path inside the copy, refusing one that a symlink leads out of it."""
    root = copy.resolve()
    target = (copy / relative).resolve()
    if root not in target.parents:
        raise RunnerError(f"{relative} resolves outside the scratch copy")
    return target


def plan_edits(copy, mutants):
    """Returns each mutant's final file texts, refusing the whole run before any build if one is ambiguous.

    Edits are replayed in order, so each must match exactly once in the text as the earlier edits
    of the same mutant left it; the planned texts are what the run writes, so the tested mutant is
    the one the spec describes.
    """
    plans = {}
    # macOS volumes usually ignore case, so two spellings can name one file. Every target is keyed by
    # its file identity, so aliases share one planned text and one restore.
    canonical = {}
    for mutant in mutants:
        texts = {}
        for edit in mutant["edits"]:
            target = confined(copy, edit["path"])
            if not target.is_file():
                raise RunnerError(f"mutant {mutant['name']}: {edit['path']} does not exist")
            stat = target.stat()
            target = canonical.setdefault((stat.st_dev, stat.st_ino), target)
            if target not in texts:
                texts[target] = target.read_bytes().decode("utf-8")
            # Every starting offset counts, overlapping ones included: "aa" occurs twice in "aaa".
            count = len(re.findall(f"(?={re.escape(edit['old'])})", texts[target]))
            if count != 1:
                raise RunnerError(f"mutant {mutant['name']}: old text occurs {count} times in {edit['path']} "
                                  "where this edit applies")
            texts[target] = texts[target].replace(edit["old"], edit["new"], 1)
        plans[mutant["name"]] = texts
    return plans


def run_tests(copy, derived_data, tests, log_path, xcodebuild, xcodegen, interrupts, expected, deadlines):
    """Generates the project, refusing to test if generation changed an intended edit target.

    deadlines holds the test run's and each short tool's, in seconds. A test run, build included,
    that has not finished by its deadline is presumed hung: it is stopped as an interrupt stops it,
    killed if it has not exited within the short tools' deadline, and left without a verdict whatever
    its log holds, because the deadline, not the tests, ended it.
    """
    test_deadline, tool_deadline = deadlines
    run_shielded([xcodegen, "generate"], tool_deadline, cwd=copy)
    # Tracked files can also be generated (Sources/Info.plist is one). Planning before generation
    # alone cannot prevent the generator from erasing a mutant before the tests observe it.
    changed = [os.path.relpath(path, copy) for path, sha in digest(expected).items() if sha != expected[path]]
    if changed:
        raise RunnerError(f"project generation changed {', '.join(changed)} before {pathlib.Path(log_path).stem} "
                          "was tested; mutate its generator input instead")
    arch = run_shielded(["uname", "-m"], tool_deadline, text=True).stdout.strip()
    command = [xcodebuild, "-project", "ClipboardTTSApp.xcodeproj", "-scheme", "ClipboardTTSApp",
               "-destination", f"platform=macOS,arch={arch}", "-derivedDataPath", str(derived_data), "test"]
    command += [f"-only-testing:{t}" for t in tests]
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, cwd=copy, stdout=log, stderr=subprocess.STDOUT)
        interrupts.process = process
        if interrupts.received:
            process.terminate()
        try:
            process.wait(timeout=test_deadline)
        except subprocess.TimeoutExpired:
            # SIGTERM lets xcodebuild end the test host, which launchd started outside this process tree,
            # and its own build service; SIGKILL is left for an xcodebuild that ignores it.
            process.terminate()
            try:
                process.wait(timeout=tool_deadline)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return "NO-VERDICT", [f"the test run did not finish within {test_deadline:g} seconds and was stopped"]
        finally:
            interrupts.process = None
    return classify(pathlib.Path(log_path).read_text(errors="replace"))


def apply_plan(plan, originals):
    """Writes UTF-8 edits without newline conversion, saving original bytes for exact restoration."""
    for target, text in plan.items():
        originals.setdefault(target, target.read_bytes())
        target.write_bytes(text.encode("utf-8"))


def lies_within(path, root):
    """Whether path is root or lies below it, judged by file identity over its existing ancestors.

    Comparing spellings is not enough: a case-insensitive volume lets a differently cased path name
    a directory inside the repository.
    """
    if not root.exists():
        return False  # nothing lies within a directory that does not exist yet
    return any(candidate.exists() and os.path.samefile(candidate, root) for candidate in (path, *path.parents))


@contextlib.contextmanager
def claim_output(out):
    """Owns --out for the duration of the with block, taking it before anything in it is deleted or written.

    The runner deletes and rewrites fixed children of --out, so it accepts only a directory that is
    new, empty, or already marked as its own and not in use by another run, and refuses a child that
    is a symlink, which would carry those deletions and writes somewhere else. The lock is released
    however the block ends, and on a refusal made after it was taken, so one process can claim the
    same directory again.
    """
    marker = out / OWNERSHIP_MARKER
    if out.exists():
        if not out.is_dir():
            raise RunnerError(f"--out {out} is not a directory")
        owned = marker.is_file() and not marker.is_symlink()
        if not owned and any(out.iterdir()):
            raise RunnerError(f"--out {out} is not empty and was not created by this runner; use a new or empty directory")
    else:
        out.mkdir(parents=True)
    # The block holds this lock, so a second run cannot rebuild the copy, logs, or results beneath it.
    # A symlinked marker never gets here: it is not ownership, and it makes --out non-empty. Closing
    # the only descriptor releases the lock; no child inherits it.
    lock = os.open(marker, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RunnerError(f"--out {out} is in use by another run") from None
        # The earlier results go first, so no later refusal can leave them looking like this run's.
        results = out / "results.json"
        if results.is_symlink():
            raise RunnerError(f"{results} is a symlink; refusing to delete or write through it")
        results.unlink(missing_ok=True)
        for name in OWNED_CHILDREN:
            if (out / name).is_symlink():
                raise RunnerError(f"{out / name} is a symlink; refusing to delete or write through it")
        yield
    finally:
        os.close(lock)


class Interrupts:
    """Records SIGINT and SIGTERM and stops the running test tool, without raising anywhere.

    A handler that raised could land between a mutant's test run and its restore and skip the
    restore; recording the signal leaves the runner to finish restoring before it stops.
    """

    def __init__(self):
        self.received = []
        self.process = None

    def __call__(self, signum, _frame):
        self.received.append(signum)
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("spec")
    parser.add_argument("--out", required=True)
    parser.add_argument("--only", nargs="+", default=None)
    parser.add_argument("--test-deadline", type=positive_seconds, default=TEST_DEADLINE, metavar="SECONDS",
                        help="stop a test run, build included, still going after this long (default %(default)g)")
    parser.add_argument("--xcodebuild", default="xcodebuild", help=argparse.SUPPRESS)
    parser.add_argument("--xcodegen", default="xcodegen", help=argparse.SUPPRESS)
    parser.add_argument("--tool-deadline", type=tool_seconds, default=TOOL_DEADLINE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    here = pathlib.Path(__file__).resolve().parent
    out = pathlib.Path(args.out).resolve()
    # --out is owned from its claim, before anything in it is deleted, until results.json is written:
    # leaving this block by any path, a refusal, a return, or an exception, releases it.
    with contextlib.ExitStack() as ownership:
        try:
            repo = pathlib.Path(git(here, "rev-parse", "--show-toplevel", text=True).stdout.strip()).resolve()
            if lies_within(out, repo):
                raise RunnerError("--out must lie outside the repository")
            # The reverse matters too: rebuilding the copy deletes what lies inside --out.
            if lies_within(repo, out):
                raise RunnerError("--out must not contain the repository")
            # Artifacts from an earlier invocation must never read as this one's evidence.
            ownership.enter_context(claim_output(out))
            if (out / "logs").exists():
                shutil.rmtree(out / "logs")
            spec_bytes = pathlib.Path(args.spec).read_bytes()
            spec = load_spec(spec_bytes)
            mutants = spec["mutants"]
            if args.only is not None:
                unknown = set(args.only) - {m["name"] for m in mutants}
                if unknown:
                    raise RunnerError(f"unknown mutants: {', '.join(sorted(unknown))}")
                mutants = [m for m in mutants if m["name"] in args.only]
            tests = spec.get("tests") or ["ClipboardTTSAppTests"]
            copy, derived_data, logs = out / "copy", out / "derived-data", out / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            build_copy(repo, copy, spec.get("untracked", []))
            # The target state is identified before generation adds files or any mutant is written.
            report = {"complete": False, "exit": 1, "error": "the runner raised an unexpected exception",
                      "head": git(repo, "rev-parse", "HEAD", text=True).stdout.strip(),
                      "spec_sha256": hashlib.sha256(spec_bytes).hexdigest(), "target_sha256": tree_digest(copy),
                      "tests": tests, "selected": [m["name"] for m in mutants],
                      "deadlines": {"test_run": args.test_deadline, "short_tool": args.tool_deadline},
                      "control": None, "mutants": []}
            plans = plan_edits(copy, mutants)
        except (RunnerError, subprocess.CalledProcessError, ValueError, OSError) as error:
            print(f"error: {describe(error)}", file=sys.stderr)
            return 2

        interrupts = Interrupts()
        signal.signal(signal.SIGINT, interrupts)
        signal.signal(signal.SIGTERM, interrupts)
        touched = sorted({target for plan in plans.values() for target in plan})
        deadlines = (args.test_deadline, args.tool_deadline)
        pristine = digest(touched)
        try:
            verdict, details = run_tests(copy, derived_data, tests, logs / "control.log", args.xcodebuild, args.xcodegen,
                                         interrupts, pristine, deadlines)
            report["control"] = {"verdict": verdict, "details": details}
            print(f"control: {verdict} {'; '.join(details)}".rstrip(), flush=True)
            if interrupts.received:
                raise RunnerError(f"interrupted by signal {interrupts.received[0]}")
            if verdict != "SURVIVED":
                raise RunnerError("the unmutated control did not pass, so no mutant verdict can be trusted")
            unmatched = selectors_without_tests((logs / "control.log").read_text(errors="replace"), tests)
            if unmatched:
                raise RunnerError(f"the control ran no test for {', '.join(unmatched)}")
            for mutant in mutants:
                originals = {}
                try:
                    apply_plan(plans[mutant["name"]], originals)
                    verdict, details = run_tests(copy, derived_data, tests, logs / f"{mutant['name']}.log",
                                                 args.xcodebuild, args.xcodegen, interrupts, digest(touched), deadlines)
                finally:
                    for target, original in originals.items():
                        target.write_bytes(original)
                    # A mutant of a generator input leaves generated files behind unless they are rebuilt, and
                    # a regeneration that fails for any reason leaves them unknown, so its failure stops the run.
                    run_shielded([args.xcodegen, "generate"], args.tool_deadline, cwd=copy)
                    if digest(touched) != pristine:
                        raise RunnerError(f"the copy was not restored after {mutant['name']}")
                if interrupts.received:
                    raise RunnerError(f"interrupted by signal {interrupts.received[0]}; the copy was restored")
                if verdict == "SURVIVED":
                    # As for the control: a selector none of whose tests ran says nothing about this mutant.
                    log = (logs / f"{mutant['name']}.log").read_text(errors="replace")
                    unmatched = selectors_without_tests(log, tests)
                    if unmatched:
                        verdict, details = "NO-TESTS", [f"no test ran for {selector}" for selector in unmatched]
                report["mutants"].append({"name": mutant["name"], "verdict": verdict, "details": details})
                print(f"{mutant['name']}: {verdict} {'; '.join(details)}".rstrip(), flush=True)
            unjudged = any(r["verdict"] in ("NO-VERDICT", "NO-TESTS", "FAILED-UNNAMED") for r in report["mutants"])
            report.update(complete=True, exit=1 if unjudged else 0, error=None)
        except (RunnerError, subprocess.CalledProcessError, OSError) as error:
            report.update(exit=2, error=describe(error))
            print(f"error: {report['error']}", file=sys.stderr)
        finally:
            # Written however the runner ends once the control began, except by a signal it does not handle.
            (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        return report["exit"]

if __name__ == "__main__":
    sys.exit(main())
