#!/usr/bin/env python3
"""Verifies run-mutants.py without Xcode, a build, or the network.

The classification cases feed `classify` the log shapes xcodebuild actually produces, including
the two that mislead an exit-code or summary reading. The end-to-end cases run the real script
inside a throwaway git repository whose `xcodebuild` and `xcodegen` are stand-ins: the stand-in
test run reads the scratch copy and prints the log a real run would print for what it finds, so
each case proves which state the copy was in when the tests ran and after the runner finished.
"""

import ast
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
RUNNER = HERE / "run-mutants.py"

SUCCEEDED = "Test Suite 'All tests' passed.\n\t Executed 3 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **\n"
NAMED = "/x/Tests/A.swift:9: error: -[ClipboardTTSAppTests.ASuite testGuard] : XCTAssertTrue failed\n"

CLASSIFY_CASES = [
    ("a passing run survives", SUCCEEDED, ("SURVIVED", [])),
    ("an expected failure in a passing run is not a kill",
     "TerminalStateAssertion.swift:54: Expected failure in -[ClipboardTTSAppTests.T testX]: failed\n" + SUCCEEDED,
     ("SURVIVED", [])),
    ("a named failure kills", NAMED + "\t Executed 3 tests, with 1 failure (0 unexpected)\n** TEST FAILED **\n",
     ("KILLED", ["ClipboardTTSAppTests.ASuite testGuard"])),
    ("every named failure is reported, not only the first",
     NAMED + "/x/Tests/A.swift:12: error: -[ClipboardTTSAppTests.ASuite testOther] : failed\n** TEST FAILED **\n",
     ("KILLED", ["ClipboardTTSAppTests.ASuite testGuard", "ClipboardTTSAppTests.ASuite testOther"])),
    ("an over-fulfilment abort reporting zero tests still kills",
     NAMED + "\t Executed 0 tests, with 0 failures (0 unexpected)\n** TEST FAILED **\n",
     ("KILLED", ["ClipboardTTSAppTests.ASuite testGuard"])),
    ("a compile error is a build failure, not a kill",
     "/x/Sources/B.swift:3:1: error: cannot find 'y' in scope\nTesting cancelled because the build failed.\n** TEST FAILED **\n",
     ("BUILD-FAILED", ["/x/Sources/B.swift:3:1: error: cannot find 'y' in scope"])),
    ("a lint failure in the build is a build failure",
     "/x/Sources/B.swift:3:1: error: Vertical Whitespace Violation\nThe following build commands failed:\n\tPhaseScriptExecution SwiftLint\n** TEST FAILED **\n",
     ("BUILD-FAILED", ["/x/Sources/B.swift:3:1: error: Vertical Whitespace Violation"])),
    ("a log still being written has no verdict despite a per-suite summary",
     "Test Suite 'ASuite' passed.\n\t Executed 3 tests, with 0 failures (0 unexpected)\n",
     ("NO-VERDICT", [])),
    ("a success that executed no test is not a survival",
     "Test Suite 'Selected tests' passed.\n\t Executed 0 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **\n",
     ("NO-TESTS", [])),
    ("a success with no execution summary is not a survival", "** TEST SUCCEEDED **\n", ("NO-TESTS", [])),
    ("the whole run's summary decides, not an earlier suite's",
     "\t Executed 0 tests, with 0 failures (0 unexpected)\n\t Executed 2 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **\n",
     ("SURVIVED", [])),
    ("success text inside test output does not override the final failure",
     "Test Suite 'ASuite' passed.\n\t Executed 3 tests, with 0 failures (0 unexpected)\nprinted: ** TEST SUCCEEDED **\n"
     "** TEST SUCCEEDED **\nRestarting after unexpected exit, crash, or test timeout\n** TEST FAILED **\n",
     ("FAILED-UNNAMED", [])),
    ("marker text that is not a standalone line is not a terminal marker",
     "\t Executed 3 tests, with 0 failures (0 unexpected)\nprinted: ** TEST SUCCEEDED **\n", ("NO-VERDICT", [])),
    ("failure-shaped text in a passing run is not a kill", NAMED + SUCCEEDED, ("SURVIVED", [])),
    ("an expected failure in a failed run is not reported as a killing test",
     "TerminalStateAssertion.swift:54: Expected failure in -[ClipboardTTSAppTests.T testX]: failed\n" + NAMED + "** TEST FAILED **\n",
     ("KILLED", ["ClipboardTTSAppTests.ASuite testGuard"])),
    ("build-failure text in a passing run is not a build failure",
     "note: The following build commands failed: (quoted by a test)\n" + SUCCEEDED, ("SURVIVED", [])),
    ("a run with a skipped test beside one that ran survives (Xcode 27's own summary)",
     "\t Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
     "\t Executed 3 tests, with 2 tests skipped and 0 failures (0 unexpected) in 0.003 (0.007) seconds\n** TEST SUCCEEDED **\n",
     ("SURVIVED", [])),
    ("a single executed test survives (Xcode 27's singular summary)",
     "Test Suite 'Selected tests' passed.\n\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n"
     "** TEST SUCCEEDED **\n", ("SURVIVED", [])),
    ("one skipped test beside ones that ran survives (Xcode 27's singular skipped summary)",
     "\t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.003 (0.007) seconds\n** TEST SUCCEEDED **\n",
     ("SURVIVED", [])),
    ("a run whose every test skipped ran nothing",
     "\t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.002 (0.002) seconds\n** TEST SUCCEEDED **\n",
     ("NO-TESTS", [])),
    ("a finished failure that names no test is not a kill",
     "Restarting after unexpected exit, crash, or test timeout\n** TEST FAILED **\n",
     ("FAILED-UNNAMED", [])),
]

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
import os, pathlib, signal, sys, time
target = pathlib.Path("Sources/Target.swift").read_text()
tests = [a for a in sys.argv if a.startswith("-only-testing:")]
record = pathlib.Path(os.environ["RUNNER_VERIFY_RECORD"])
with open(record, "a") as f:
    f.write(repr((target.strip(), tests, sys.argv[1:])) + "\n")
assert pathlib.Path("Sources/Dirty.swift").read_text() == "uncommitted\n", "the tracked diff was not applied"
for selector in (t.split(":", 1)[1] for t in tests):
    if "Nope" not in selector:  # a misspelled selector matches nothing, as in a real run
        parts = selector.split("/")
        case = (parts + ["DefaultSuite", "testOne"])[:3] if len(parts) < 3 else parts
        print(f"Test Case '-[{case[0]}.{case[1]} {case[2].removesuffix('()')}]' started.")
        if "Skipped" in selector or ("SKIP_B" in target and "BSuite" in selector):  # skips as XCTSkip reports it
            print(f"Test Case '-[{case[0]}.{case[1]} {case[2].removesuffix('()')}]' skipped (0.001 seconds).")
print("PROJECT:", pathlib.Path("project.yml").read_text().strip())
if "HOLD" in target:  # holds the run open until the case releases it, so another run can meet it
    # A runner killed by a case's timeout leaves this orphaned, after which no release can reach it.
    while not pathlib.Path(os.environ["RUNNER_VERIFY_RELEASE"]).exists() and os.getppid() != 1:
        time.sleep(0.05)
if "PRELAUNCH" in pathlib.Path("project.yml").read_text():
    time.sleep(3)
    with open(record, "a") as f:
        f.write(repr(("finished", tests)) + "\n")
if os.environ.get("RUNNER_VERIFY_NO_UNTRACKED"):
    assert not pathlib.Path("Tests/New.swift").exists(), "an unnamed untracked file was copied"
else:
    assert pathlib.Path("Tests/New.swift").exists(), "the named untracked file was not copied"
assert not pathlib.Path("ignored.log").exists(), "ignored content was copied"
if "CONTROL_FAILS" in target:
    print("/x/Tests/A.swift:1: error: -[S testControl] : failed\n** TEST FAILED **")
elif "CRASH" in target:
    print("Restarting after unexpected exit, crash, or test timeout\n** TEST FAILED **")
elif "KILL" in target:
    print("/x/Tests/A.swift:9: error: -[ClipboardTTSAppTests.ASuite testGuard] : XCTAssertTrue failed\n** TEST FAILED **")
elif "BUILD" in target:
    print("/x/Sources/Target.swift:1:1: error: expected declaration\nTesting cancelled because the build failed.\n** TEST FAILED **")
elif "PARTIAL" in target:
    print("\t Executed 3 tests, with 0 failures (0 unexpected)")
elif "NOTESTS" in target:
    print("\t Executed 0 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **")
elif "GROUPINT" in target:  # a terminal's Ctrl-C signals the runner's whole process group
    os.killpg(os.getpgid(os.getppid()), signal.SIGINT)
    time.sleep(20)  # only a test tool outside that group, which the runner then failed to stop, waits this out
    with open(record, "a") as f:
        f.write(repr(("finished", tests)) + "\n")
elif "HANGUP" in target:  # so does a terminal's hangup, which the runner does not handle
    with open(record, "a") as f:
        f.write(repr(("hanging up", os.getpid())) + "\n")
    os.killpg(os.getpgid(os.getppid()), signal.SIGHUP)
    # A signal sent to the sender's own group reaches it before killpg returns, so only a tool outside it gets here.
    with open(record, "a") as f:
        f.write(repr(("outlived the hangup", os.getpid())) + "\n")
elif "CTRLC" in target or "INTERRUPT" in target:
    os.kill(os.getppid(), signal.SIGINT if "CTRLC" in target else signal.SIGTERM)
    time.sleep(20)  # only a runner that failed to stop the test tool waits this out
    with open(record, "a") as f:
        f.write(repr(("finished", tests)) + "\n")
elif "STALL" in target or "STUBBORN" in target:  # never finishes, as a run with a deadlocked test does
    def note(what):
        with open(record, "a") as f:
            f.write(repr((what, os.getpid())) + "\n")
    if "STUBBORN" in target:  # a tool that ignores the stop, after a log that would otherwise read as a survival
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print("\t Executed 3 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **", flush=True)
    else:
        signal.signal(signal.SIGTERM, lambda *_: (note("stopped"), os._exit(143)))
    note("stalling")
    while os.getppid() != 1:  # only a runner that has gone without stopping it lets this end
        time.sleep(0.05)
    note("outlived the runner")
elif "SLOW" in target:  # finishes, but only after longer than the short tools' deadline
    time.sleep(4)
    print("/x/Tests/A.swift:9: error: -[ClipboardTTSAppTests.ASuite testGuard] : XCTAssertTrue failed\n** TEST FAILED **")
else:
    print("\t Executed 3 tests, with 0 failures (0 unexpected)\n** TEST SUCCEEDED **")
'''


SELECTOR_CASES = [
    ("a bundle selector matches any case in it", ["ClipboardTTSAppTests"], []),
    ("a suite selector matches that suite", ["ClipboardTTSAppTests/ASuite"], []),
    ("a test selector matches that test, with or without parentheses",
     ["ClipboardTTSAppTests/ASuite/testGuard", "ClipboardTTSAppTests/ASuite/testGuard()"], []),
    ("another suite is not matched", ["ClipboardTTSAppTests/BSuite"], ["ClipboardTTSAppTests/BSuite"]),
    ("another test in the suite is not matched", ["ClipboardTTSAppTests/ASuite/testOther"],
     ["ClipboardTTSAppTests/ASuite/testOther"]),
    ("another bundle is not matched", ["OtherTests"], ["OtherTests"]),
    ("a passed line is not a start", None, ["ClipboardTTSAppTests"]),
    ("a suite whose every test skipped ran nothing", ["ClipboardTTSAppTests/SkipSuite"], ["ClipboardTTSAppTests/SkipSuite"]),
    ("a suite with a skipped test beside one that ran is matched", ["ClipboardTTSAppTests/MixedSuite"], []),
]
SELECTOR_LOG = ("Test Case '-[ClipboardTTSAppTests.ASuite testGuard]' started.\n"
                "Test Case '-[ClipboardTTSAppTests.SkipSuite testSkips]' started.\n"
                "Test Case '-[ClipboardTTSAppTests.SkipSuite testSkips]' skipped (0.002 seconds).\n"
                "Test Case '-[ClipboardTTSAppTests.MixedSuite testRuns]' started.\n"
                "Test Case '-[ClipboardTTSAppTests.MixedSuite testRuns]' passed (0.001 seconds).\n"
                "Test Case '-[ClipboardTTSAppTests.MixedSuite testSkips]' started.\n"
                "Test Case '-[ClipboardTTSAppTests.MixedSuite testSkips]' skipped (0.001 seconds).\n")
PASSED_ONLY_LOG = "Test Case '-[ClipboardTTSAppTests.ASuite testGuard]' passed (0.001 seconds).\n"
# Stands in for a short tool that never finishes. The tool notes its pid and waits until the runner that started it
# has gone, which a runner that killed it never lets happen, and notes that instead. It starts a helper, which moves
# to a process group of its own but stays in the tool's session and, once a fork is requested, starts a late member
# there too; both note their pids and wait to be killed, even once orphaned. A holder, which a tool starts in a
# session of its own, keeps that tool's output open after the tool has finished, until it is released. Whatever
# waits gives up after a minute, so a case that failed leaves nothing running for long.
STALLING_TOOL = r'''#!/usr/bin/env python3
import os, signal, subprocess, sys, time
role = sys.argv[1] if len(sys.argv) > 1 else "tool"
def note(what):
    with open(os.environ["RUNNER_VERIFY_RECORD"], "a") as f:
        f.write(repr((what, role, os.getpid())) + "\n")
if role == "tool":
    subprocess.Popen([sys.executable, __file__, "helper"])
if role != "holder":  # only a kill ends a tool that hangs this way
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if role == "helper":  # so that stopping the tool's process group alone would miss it
    os.setpgid(0, 0)
note("stalling")
if role == "tool":
    while os.getppid() != 1:
        time.sleep(0.05)
    note("outlived what started it")
    sys.exit()
give_up, fork = time.monotonic() + 60, os.environ.get("RUNNER_VERIFY_FORK")
while not os.path.exists(os.environ.get("RUNNER_VERIFY_RELEASE", "")) and time.monotonic() < give_up:
    if role == "helper" and fork and os.path.exists(fork):
        subprocess.Popen([sys.executable, __file__, "late"])
        fork = None
    time.sleep(0.05)
'''
# What a terminal's Ctrl-C does, sent from inside a stand-in tool that the runner started: signal the runner's
# whole process group, which holds the tool too unless the runner started it outside that group.
GROUP_SIGINT = "kill -s INT -- -$(ps -o pgid= -p $PPID | tr -d ' ')\n"


def load_runner():
    # Importing the runner must not leave a bytecode cache in the repository.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("run_mutants", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_repo(root, target_text="let value = ORIGINAL\n"):
    repo = root / "repo"
    (repo / "Sources").mkdir(parents=True)
    (repo / "Tests").mkdir()
    (repo / "run-mutants.py").write_text(RUNNER.read_text())
    (repo / "Sources" / "Target.swift").write_text(target_text)
    (repo / "Sources" / "Dirty.swift").write_text("committed\n")
    (repo / ".gitignore").write_text("ignored.log\n")
    (repo / "project.yml").write_text("name: SPEC_ORIGINAL\n")
    (repo / "Sources" / "Escape").symlink_to("../..")
    run = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
    run("init", "-q")
    run("add", ".")
    run("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "fixture")
    (repo / "Sources" / "Dirty.swift").write_text("uncommitted\n")
    (repo / "Tests" / "New.swift").write_text("new\n")
    (repo / "ignored.log").write_text("must not be copied\n")
    tools = root / "tools"
    tools.mkdir()
    (tools / "xcodebuild").write_text(FAKE_XCODEBUILD)
    (tools / "stall").write_text(STALLING_TOOL)
    # Stands in for generation: the generated file mirrors the project spec it was generated from. When
    # it regenerates over a mutant's INTERRUPT state, it signals the runner mid-cleanup first.
    (tools / "xcodegen").write_text(
        "#!/bin/sh\n"
        "if grep -q PRELAUNCH project.yml; then kill -TERM $PPID; fi\n"
        "if grep -q SPEC_BROKEN project.yml; then echo 'SPEC_BROKEN is not a valid spec' >&2; exit 1; fi\n"
        "if grep -q INTERRUPT Generated.txt 2>/dev/null && ! grep -q INTERRUPT project.yml; then\n"
        "  kill -TERM $PPID\n  sleep 1\nfi\n"
        # A terminal's Ctrl-C, before a mutant's test run or while regenerating over it after its restore.
        "if grep -q SPEC_CTRLC_BEFORE project.yml || { grep -q SPEC_CTRLC_AFTER Generated.txt 2>/dev/null &&\n"
        "    ! grep -q SPEC_CTRLC_AFTER project.yml; }; then\n  " + GROUP_SIGINT + "fi\n"
        "if grep -q SPEC_REGEN_FAILS Generated.txt 2>/dev/null && ! grep -q SPEC_REGEN_FAILS project.yml; then\n"
        "  echo 'cannot regenerate over SPEC_REGEN_FAILS' >&2; exit 1\nfi\n"
        # Never finishes, before a mutant's test run or while regenerating over it after its restore.
        "if grep -q SPEC_STALL_BEFORE project.yml || { grep -q SPEC_STALL_AFTER Generated.txt 2>/dev/null &&\n"
        "    ! grep -q SPEC_STALL_AFTER project.yml; }; then\n  exec \"$(dirname \"$0\")/stall\"\nfi\n"
        "cp project.yml Generated.txt\n")
    for tool in ("xcodebuild", "xcodegen", "stall"):
        (tools / tool).chmod(0o755)
    return repo, tools


def run_runner(root, repo, tools, mutants, extra=(), out=None, untracked=("Tests/New.swift",),
               tests=("ClipboardTTSAppTests/ASuite",), ignore_sigint=False, own_session=False, env=None):
    spec = root / "spec.json"
    spec.write_text(json.dumps({"tests": list(tests), "untracked": list(untracked),
                                "mutants": mutants}))
    out = out or root / "out"
    record = root / "record.txt"
    record.write_text("")
    env = dict(os.environ, RUNNER_VERIFY_RECORD=str(record), **(env or {}))

    def prepare():
        if ignore_sigint:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
        if own_session:  # a hangup's default action, as a terminal's job has, even if this verifier runs under nohup
            signal.signal(signal.SIGHUP, signal.SIG_DFL)

    # own_session starts the runner as a terminal starts a job, as its own process group, which the stand-ins can
    # then signal as the terminal would without reaching this verifier.
    result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(out),
                             "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen"), *extra],
                            capture_output=True, text=True, env=env, timeout=60, start_new_session=own_session,
                            preexec_fn=prepare if ignore_sigint or own_session else None)
    runs = [ast.literal_eval(line) for line in record.read_text().splitlines()]
    return result, out, runs


def ignores_case(directory):
    """Whether the volume holding directory treats differently cased names as one."""
    probe = directory / "CASEPROBE"
    probe.write_text("")
    try:
        return (directory / "caseprobe").exists()
    finally:
        probe.unlink()


def mutant(name, new):
    return {"name": name, "edits": [{"path": "Sources/Target.swift", "old": "ORIGINAL", "new": new}]}


def end_to_end_cases():
    failures = []

    def case(name, check):
        failed = False
        try:
            with tempfile.TemporaryDirectory() as tmp:
                try:
                    check(pathlib.Path(tmp))
                except Exception as error:  # a crash is this case's failure, not the whole verifier's
                    failed = True
                    failures.append(f"{name}: {type(error).__name__}: {error}")
        except OSError as error:  # so is a process the runner left behind, still writing where the case cleans up
            if not failed:
                failures.append(f"{name}: cleanup failed: {error}")

    def verdicts_and_restore(root):
        repo, tools = make_repo(root)
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL"), mutant("survive", "SURVIVOR"),
                                                           mutant("build", "BUILD"), mutant("partial", "PARTIAL")])
        lines = dict(line.split(":", 1) for line in result.stdout.splitlines())
        assert result.returncode == 1, f"a mutant with no verdict must exit 1, got {result.returncode}: {result.stderr}"
        assert lines["control"].strip() == "SURVIVED", lines
        assert lines["kill"].strip() == "KILLED ClipboardTTSAppTests.ASuite testGuard", lines
        assert lines["survive"].strip() == "SURVIVED", lines
        assert lines["build"].strip().startswith("BUILD-FAILED"), lines
        assert lines["partial"].strip() == "NO-VERDICT", lines
        assert [r[0] for r in runs] == ["let value = ORIGINAL", "let value = KILL", "let value = SURVIVOR",
                                        "let value = BUILD", "let value = PARTIAL"], runs
        assert all(r[1] == ["-only-testing:ClipboardTTSAppTests/ASuite"] for r in runs), runs
        arch = subprocess.run(["uname", "-m"], check=True, capture_output=True, text=True).stdout.strip()
        command = ["-project", "ClipboardTTSApp.xcodeproj", "-scheme", "ClipboardTTSApp",
                   "-destination", f"platform=macOS,arch={arch}", "-derivedDataPath", str(out.resolve() / "derived-data"),
                   "test", "-only-testing:ClipboardTTSAppTests/ASuite"]
        assert all(r[2] == command for r in runs), f"the test command changed, or its build products left --out: {runs}"
        assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n"
        report = json.loads((out / "results.json").read_text())
        assert [r["name"] for r in report["mutants"]] == ["kill", "survive", "build", "partial"], report
        assert report["complete"] and report["exit"] == result.returncode == 1 and report["error"] is None, report
        assert (repo / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n", "the repository was edited"

    def every_judged_verdict_exits_zero(root):
        repo, tools = make_repo(root)
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL"), mutant("survive", "SURVIVOR"),
                                                       mutant("build", "BUILD"), mutant("crash", "CRASH")])
        assert result.returncode == 0, f"a build failure or an unnamed failure is a verdict: {result.returncode}"
        lines = dict(line.split(":", 1) for line in result.stdout.splitlines())
        assert lines["build"].strip().startswith("BUILD-FAILED") and lines["crash"].strip() == "FAILED-UNNAMED", lines

    def omitted_tests_and_untracked_take_their_defaults(root):
        repo, tools = make_repo(root)
        spec = root / "raw.json"
        spec.write_text(json.dumps({"mutants": [mutant("kill", "KILL")]}))
        record = root / "record.txt"
        record.write_text("")
        result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(root / "out"),
                                 "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")],
                                capture_output=True, text=True, timeout=60,
                                env=dict(os.environ, RUNNER_VERIFY_RECORD=str(record), RUNNER_VERIFY_NO_UNTRACKED="1"))
        runs = [ast.literal_eval(line) for line in record.read_text().splitlines()]
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert [r[1] for r in runs] == [["-only-testing:ClipboardTTSAppTests"]] * 2, f"the whole bundle was not selected: {runs}"
        assert not (root / "out" / "copy" / "Tests" / "New.swift").exists()

    def a_mutant_of_two_files_is_tested_and_restored_whole(root):
        repo, tools = make_repo(root)
        two = {"name": "two.files_a", "edits": [  # its name also uses '.' and '_'; other names use '-'
            {"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_TWO"},
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL"}]}
        result, out, runs = run_runner(root, repo, tools, [two])
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert "two.files_a: KILLED ClipboardTTSAppTests.ASuite testGuard" in result.stdout, result.stdout
        assert "PROJECT: name: SPEC_TWO" in (out / "logs" / "two.files_a.log").read_text(), "the first file's edit was not applied"
        for path in ("project.yml", "Sources/Target.swift"):
            assert (out / "copy" / path).read_bytes() == (repo / path).read_bytes(), f"{path} was not restored"

    def results_identify_their_run(root):
        repo, tools = make_repo(root)
        head = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True, capture_output=True,
                              text=True).stdout.strip()
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL"), mutant("survive", "SURVIVOR")])
        # The digest covers the spec's own bytes, which a reformatting that parses the same must change.
        spec = root / "spec.json"
        spec.write_text(json.dumps(json.loads(spec.read_text()), indent=3) + "\n")
        result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(out),
                                 "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")],
                                capture_output=True, text=True, timeout=60,
                                env=dict(os.environ, RUNNER_VERIFY_RECORD=str(root / "record.txt")))
        report = json.loads((out / "results.json").read_text())
        assert result.returncode == 0 and report["exit"] == 0 and report["complete"] and report["error"] is None, report
        assert report["head"] == head and report["tests"] == ["ClipboardTTSAppTests/ASuite"], report
        assert report["spec_sha256"] == hashlib.sha256((root / "spec.json").read_bytes()).hexdigest(), report
        assert report["selected"] == ["kill", "survive"] and report["control"] == {"verdict": "SURVIVED", "details": []}
        assert [(r["name"], r["verdict"]) for r in report["mutants"]] == [("kill", "KILLED"), ("survive", "SURVIVED")]
        target = report["target_sha256"]
        # The same target state gives the same identity whichever mutants run; any change to it gives another.
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL"), mutant("survive", "SURVIVOR")], out=out,
                                  extra=("--only", "survive"))
        report = json.loads((out / "results.json").read_text())
        assert report["target_sha256"] == target and report["selected"] == ["survive"], report
        assert [r["name"] for r in report["mutants"]] == ["survive"], report
        for change in (lambda: (repo / "Tests" / "New.swift").write_text("changed\n"),
                       lambda: (repo / "Sources" / "Dirty.swift").chmod(0o755),
                       lambda: (repo / "Sources" / "Link.swift").symlink_to("Dirty.swift")):
            change()
            if (repo / "Sources" / "Link.swift").is_symlink():
                subprocess.run(["git", "-C", str(repo), "add", "Sources/Link.swift"], check=True)
            run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
            changed = json.loads((out / "results.json").read_text())["target_sha256"]
            assert changed != target, "a changed target state kept its identity"
            target = changed
        repo, tools = make_repo(root / "interrupted")
        result, out, _ = run_runner(root / "interrupted", repo, tools, [mutant("kill", "KILL"), mutant("interrupt", "INTERRUPT")])
        report = json.loads((out / "results.json").read_text())
        assert result.returncode == 2 and report["exit"] == 2 and not report["complete"], report
        assert "interrupted" in report["error"] and [r["name"] for r in report["mutants"]] == ["kill"], report

    def a_second_run_on_a_directory_in_use_is_refused(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // HOLD\n")
        spec = root / "spec.json"
        spec.write_text(json.dumps({"tests": ["ClipboardTTSAppTests/ASuite"], "untracked": ["Tests/New.swift"],
                                    "mutants": [mutant("kill", "KILL")]}))
        out, release = root / "out", root / "release"
        command = [sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(out),
                   "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")]
        records = [root / "first.txt", root / "second.txt"]
        for record in records:
            record.write_text("")
        env = dict(os.environ, RUNNER_VERIFY_RELEASE=str(release))
        first = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 env=dict(env, RUNNER_VERIFY_RECORD=str(records[0])))
        try:
            for _ in range(600):  # the first run's control has started and is holding
                if records[0].read_text() or first.poll() is not None:
                    break
                time.sleep(0.05)
            assert records[0].read_text() and first.poll() is None, "the first run never reached its control"
            second = subprocess.run(command, capture_output=True, text=True, timeout=30,
                                    env=dict(env, RUNNER_VERIFY_RECORD=str(records[1])))
            assert second.returncode == 2 and "in use by another run" in second.stderr, (second.returncode, second.stderr)
            assert records[1].read_text() == "" and (out / "logs" / "control.log").exists(), "the second run touched it"
        finally:
            release.write_text("")
            stdout, stderr = first.communicate(timeout=60)
        assert first.returncode == 0 and "kill: KILLED" in stdout, (first.returncode, stderr)
        assert json.loads((out / "results.json").read_text())["complete"]

    def only_selects(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL"), mutant("survive", "SURVIVOR")],
                                     extra=("--only", "survive"))
        assert result.returncode == 0, result.stderr
        assert [r[0] for r in runs] == ["let value = ORIGINAL", "let value = SURVIVOR"], runs

    def interrupted_run_restores(root):
        repo, tools = make_repo(root)
        # A process a non-interactive shell starts in the background inherits SIGINT as ignored, and
        # Python then installs no handler of its own, so the runner must install one explicitly.
        for marker, signal_name in (("INTERRUPT", "SIGTERM"), ("CTRLC", "SIGINT")):
            result, out, runs = run_runner(root, repo, tools, [mutant("interrupt", marker), mutant("later", "KILL")],
                                           ignore_sigint=marker == "CTRLC")
            assert result.returncode == 2, f"{signal_name}: an interrupted run must exit 2, got {result.returncode}"
            assert "interrupted" in result.stderr, (signal_name, result.stderr)
            assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n", signal_name
            assert [r[0] for r in runs] == ["let value = ORIGINAL", f"let value = {marker}"], (signal_name, runs)
            assert result.returncode == 2 and "finished" not in [r[0] for r in runs], "the test tool was not stopped"

    def every_test_selector_is_passed(root):
        repo, tools = make_repo(root)
        tests = ("ClipboardTTSAppTests/ASuite", "ClipboardTTSAppTests/BSuite/testOne")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], tests=tests)
        assert result.returncode == 0, result.stderr
        assert all(r[1] == [f"-only-testing:{t}" for t in tests] for r in runs), runs

    def an_unknown_only_name_refuses(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], extra=("--only", "kill", "kil"))
        assert result.returncode == 2 and "unknown mutants: kil" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def untracked_files_are_copied_as_named_and_never_through_a_symlink(root):
        repo, tools = make_repo(root)
        (repo / "Tests" / "New File.swift").write_text("spaced\n")
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")],
                                       untracked=("Tests/New.swift", "Tests/New File.swift"))
        assert result.returncode == 0, result.stderr
        assert (out / "copy" / "Tests" / "New File.swift").read_text() == "spaced\n"
        (repo / "Tests" / "Alias.swift").symlink_to("../ignored.log")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")],
                                     untracked=("Tests/New.swift", "Tests/Alias.swift"))
        assert result.returncode == 2 and "not a symlink" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def failing_control_refuses(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // CONTROL_FAILS\n")
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "control did not pass" in result.stderr, (result.returncode, result.stderr)
        assert len(runs) == 1, runs
        report = json.loads((out / "results.json").read_text())
        assert report["mutants"] == [] and not report["complete"] and report["exit"] == 2, report
        assert report["control"]["verdict"] == "KILLED" and "control did not pass" in report["error"], report

    def ambiguous_edit_refuses_before_building(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // ORIGINAL\n")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "occurs 2 times" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def missing_edit_refuses_before_building(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [{"name": "gone", "edits": [
            {"path": "Sources/Target.swift", "old": "ABSENT", "new": "X"}]}])
        assert result.returncode == 2 and "occurs 0 times" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def out_inside_repository_refuses(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=repo / "scratch")
        assert result.returncode == 2 and "outside the repository" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and not (repo / "scratch" / "copy").exists()

    def ignored_file_cannot_be_named(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], untracked=("Tests/New.swift", "ignored.log"))
        assert result.returncode == 2 and "ignored.log" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def malformed_specs_refuse(root):
        repo, tools = make_repo(root)
        for bad, reason in [([], "no mutants"), ([mutant("control", "KILL")], "unique name"),
                            ([mutant("a", "KILL"), mutant("a", "BUILD")], "unique name"),
                            ([mutant("CONTROL", "KILL")], "regardless of case"),
                            ([mutant("case", "KILL"), mutant("CASE", "BUILD")], "regardless of case"),
                            ([mutant("../escape", "KILL")], "unique name"),
                            ([mutant("ok/x", "KILL")], "unique name"), ([mutant("ok\x00", "KILL")], "unique name"),
                            ([{"name": "noedits", "edits": []}], "list of edit objects"),
                            (["not an object"], "must be a JSON object"),
                            ([{"name": "x", "edits": "Sources/Target.swift"}], "list of edit objects"),
                            ([{"name": "same", "edits": [{"path": "Sources/Target.swift", "old": "X", "new": "X"}]}], "distinct"),
                            ([{"name": "empty", "edits": [{"path": "Sources/Target.swift", "old": "", "new": "X"}]}], "distinct")]:
            result, _, runs = run_runner(root, repo, tools, bad)
            assert result.returncode == 2 and reason in result.stderr, (bad, result.returncode, result.stderr)
            assert "Traceback" not in result.stderr and runs == [], (bad, result.stderr, runs)
        for document, reason in [("[]", "must be a JSON object"), ("null", "must be a JSON object"),
                                 ('"text"', "must be a JSON object"),
                                 ('{"tests": "ClipboardTTSAppTests", "mutants": []}', "'tests' must be a list"),
                                 ('{"untracked": [1], "mutants": []}', "'untracked' must be a list"),
                                 ('{"tests": [""], "mutants": []}', "'tests' must be a list"),
                                 ('{"untracked": ["../outside"], "mutants": []}', "without '..'"),
                                 ("{not json", "error:")]:
            spec = root / "raw.json"
            spec.write_text(document)
            result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(root / "o"),
                                     "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 2 and reason in result.stderr, (document, result.returncode, result.stderr)
            assert "Traceback" not in result.stderr, (document, result.stderr)
        spec = root / "raw.json"
        spec.write_bytes(b"\xff\xfe not text")
        result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(root / "o"),
                                 "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 2 and "Traceback" not in result.stderr, (result.returncode, result.stderr)

    def edit_paths_stay_inside_the_copy(root):
        repo, tools = make_repo(root)
        (root / "victim.txt").write_text("ORIGINAL\n")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, result.stderr
        (out / "victim.txt").write_text("ORIGINAL\n")
        for path, reason in [("../victim.txt", "without '..'"), (str(root / "victim.txt"), "without '..'"),
                             ("Sources/Escape/victim.txt", "outside the scratch copy")]:
            result, _, runs = run_runner(root, repo, tools, [{"name": "escape", "edits": [
                {"path": path, "old": "ORIGINAL", "new": "MUTATED"}]}], out=out)
            assert result.returncode == 2 and reason in result.stderr, (path, result.returncode, result.stderr)
            assert runs == [], (path, runs)
        assert (root / "victim.txt").read_text() == "ORIGINAL\n" and (out / "victim.txt").read_text() == "ORIGINAL\n"

    def edits_apply_in_order_as_specified(root):
        repo, tools = make_repo(root)
        chained = {"name": "chained", "edits": [
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL MARK"},
            {"path": "Sources/Target.swift", "old": "MARK", "new": "SECOND"}]}
        result, out, runs = run_runner(root, repo, tools, [chained])
        assert result.returncode == 0, result.stderr
        assert [r[0] for r in runs] == ["let value = ORIGINAL", "let value = KILL SECOND"], runs
        repeated = {"name": "repeated", "edits": [
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL"},
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "BUILD"}]}
        result, _, runs = run_runner(root, repo, tools, [repeated])
        assert result.returncode == 2 and "occurs 0 times" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def a_mutant_that_runs_no_test_is_unjudged(root):
        repo, tools = make_repo(root)
        result, _, _ = run_runner(root, repo, tools, [mutant("notests", "NOTESTS")])
        assert result.returncode == 1, (result.returncode, result.stderr)
        assert "notests: NO-TESTS" in result.stdout, result.stdout

    def the_tracked_diff_applies_inside_an_unrelated_repository(root):
        repo, tools = make_repo(root)
        outer = root / "outer"
        outer.mkdir()
        subprocess.run(["git", "-C", str(outer), "init", "-q"], check=True)
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=outer / "out")
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert (out / "copy" / "Sources" / "Dirty.swift").read_text() == "uncommitted\n"

    def unknown_spec_keys_refuse(root):
        repo, tools = make_repo(root)
        good = mutant("kill", "KILL")
        for document, where in [({"test": ["X"], "mutants": [good]}, "the spec"),
                                ({"mutants": [dict(good, edit=[])]}, "a mutant"),
                                ({"mutants": [{"name": "kill", "edits": [dict(good["edits"][0], paths="x")]}]}, "edit")]:
            spec = root / "raw.json"
            spec.write_text(json.dumps(document))
            result = subprocess.run([sys.executable, str(repo / "run-mutants.py"), str(spec), "--out", str(root / "o"),
                                     "--xcodebuild", str(tools / "xcodebuild"), "--xcodegen", str(tools / "xcodegen")],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 2 and "unknown keys" in result.stderr and where in result.stderr, (
                document, result.returncode, result.stderr)

    def a_refused_run_leaves_no_earlier_evidence(root):
        repo, tools = make_repo(root)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0 and (out / "results.json").exists() and (out / "logs" / "kill.log").exists()
        result, _, runs = run_runner(root, repo, tools, [mutant("control", "KILL")], out=out)
        assert result.returncode == 2 and runs == [], (result.returncode, result.stderr)
        assert not (out / "results.json").exists() and not (out / "logs").exists(), "earlier evidence survived"

    def generated_files_are_rebuilt_after_a_restore(root):
        repo, tools = make_repo(root)
        config = {"name": "config", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_MUTATED"}]}
        result, out, _ = run_runner(root, repo, tools, [config])
        assert result.returncode == 0, result.stderr
        assert (out / "copy" / "project.yml").read_text() == "name: SPEC_ORIGINAL\n"
        assert (out / "copy" / "Generated.txt").read_text() == "name: SPEC_ORIGINAL\n", "generated state kept the mutant"

    def a_foreign_output_directory_is_left_alone(root):
        repo, tools = make_repo(root)
        out = root / "shared"
        (out / "copy").mkdir(parents=True)
        (out / "copy" / "keep.txt").write_text("someone else's\n")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        assert result.returncode == 2 and "not created by this runner" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and (out / "copy" / "keep.txt").read_text() == "someone else's\n"
        assert sorted(p.name for p in out.iterdir()) == ["copy"], list(out.iterdir())

    def a_symlinked_child_is_never_written_through(root):
        for child in ("copy", "derived-data", "logs", "results.json"):
            base = root / child
            repo, tools = make_repo(base)
            result, out, _ = run_runner(base, repo, tools, [mutant("kill", "KILL")])
            assert result.returncode == 0, (child, result.stderr)
            elsewhere = base / "elsewhere"
            elsewhere.mkdir()
            (elsewhere / "keep.log").write_text("keep\n")
            if (out / child).is_dir():
                shutil.rmtree(out / child)
            (out / child).unlink(missing_ok=True)
            (out / child).symlink_to(elsewhere / "keep.log" if child == "results.json" else elsewhere)
            result, _, runs = run_runner(base, repo, tools, [mutant("kill", "KILL")], out=out)
            assert result.returncode == 2 and "is a symlink" in result.stderr, (child, result.returncode, result.stderr)
            assert runs == [] and sorted(p.name for p in elsewhere.iterdir()) == ["keep.log"], (child, runs)
            assert (elsewhere / "keep.log").read_text() == "keep\n", child

    def a_symlinked_ownership_marker_is_not_ownership(root):
        repo, tools = make_repo(root)
        (root / "marker").write_text("")
        out = root / "shared"
        (out / "copy").mkdir(parents=True)
        (out / "copy" / "keep.txt").write_text("someone else's\n")
        (out / ".run-mutants-owned").symlink_to(root / "marker")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        assert result.returncode == 2 and "not created by this runner" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and (out / "copy" / "keep.txt").read_text() == "someone else's\n"

    def a_tracked_file_replaced_by_a_directory_refuses(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Plain.swift").write_text("tracked\n")
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        git("add", "Sources/Plain.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "plain")
        (repo / "Sources" / "Plain.swift").unlink()
        (repo / "Sources" / "Plain.swift").mkdir()
        (repo / "Sources" / "Plain.swift" / "Inner.swift").write_text("untracked\n")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "neither a file nor a symlink" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def an_interrupt_during_cleanup_waits_for_it(root):
        repo, tools = make_repo(root)
        config = {"name": "config", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_INTERRUPT"}]}
        result, out, runs = run_runner(root, repo, tools, [config, mutant("later", "KILL")])
        assert result.returncode == 2 and "interrupted" in result.stderr, (result.returncode, result.stderr)
        assert (out / "copy" / "project.yml").read_text() == "name: SPEC_ORIGINAL\n"
        assert (out / "copy" / "Generated.txt").read_text() == "name: SPEC_ORIGINAL\n", "cleanup was cut short"
        assert len(runs) == 2, runs

    def a_generated_file_is_not_an_edit_target(root):
        repo, tools = make_repo(root)
        generated = {"name": "generated", "edits": [{"path": "Generated.txt", "old": "SPEC_ORIGINAL", "new": "SPEC_EDITED"}]}
        result, _, runs = run_runner(root, repo, tools, [generated])
        assert result.returncode == 2 and "Generated.txt does not exist" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def generation_cannot_erase_a_tracked_mutant_before_testing(root):
        repo, tools = make_repo(root)
        generated = repo / "Generated.txt"
        generated.write_text("name: SPEC_ORIGINAL\n")
        subprocess.run(["git", "-C", str(repo), "add", "Generated.txt"], check=True)
        edits = [{"name": "generated", "edits": [
            {"path": "Generated.txt", "old": "SPEC_ORIGINAL", "new": "SPEC_MUTATED"}]}]
        result, out, runs = run_runner(root, repo, tools, edits)
        assert result.returncode == 2 and "generation changed Generated.txt before generated was tested" in result.stderr, (
            result.returncode, result.stdout, result.stderr)
        assert len(runs) == 1, f"only the unmutated control may run: {runs}"
        report = json.loads((out / "results.json").read_text())
        assert report["mutants"] == [] and not report["complete"] and report["exit"] == 2, "an erased mutant received a verdict"
        assert (out / "copy" / "Generated.txt").read_bytes() == generated.read_bytes()
        # The control must also refuse an edit target that generation changes from the target state.
        generated.write_text("name: SPEC_ORIGINAL // dirty\n")
        result, _, runs = run_runner(root, repo, tools, edits)
        assert result.returncode == 2 and "generation changed Generated.txt before control was tested" in result.stderr, (
            result.stderr)
        assert runs == [], f"the control tested a state other than the requested target: {runs}"

    def edits_and_restore_preserve_exact_line_endings(root):
        repo, tools = make_repo(root)
        original = "let value = ORIGINAL\r\n// LF π\n// CR\r".encode("utf-8")
        (repo / "Sources" / "Target.swift").write_bytes(original)
        tool = tools / "xcodebuild"
        tool.write_text(tool.read_text().replace(
            "target = pathlib.Path", "print('OBSERVED_BYTES:', repr(pathlib.Path('Sources/Target.swift').read_bytes()))\ntarget = pathlib.Path", 1))
        edits = [mutant("kill", "KILL"), {"name": "exact-newline", "edits": [
            {"path": "Sources/Target.swift", "old": "ORIGINAL\r\n", "new": "KILL\r\n"}]}]
        result, out, runs = run_runner(root, repo, tools, edits)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert len(runs) == 3, runs
        for name, expected in (("control", original), ("kill", original.replace(b"ORIGINAL", b"KILL")),
                               ("exact-newline", original.replace(b"ORIGINAL", b"KILL"))):
            assert f"OBSERVED_BYTES: {expected!r}" in (out / "logs" / f"{name}.log").read_text(), name
        assert (out / "copy" / "Sources" / "Target.swift").read_bytes() == original
        assert (repo / "Sources" / "Target.swift").read_bytes() == original

    def restoration_is_checked_after_regeneration(root):
        repo, tools = make_repo(root)
        generator = tools / "xcodegen"
        generator.write_text(generator.read_text().replace(
            "cp project.yml Generated.txt",
            "if grep -q SPEC_MUTATED Generated.txt 2>/dev/null && grep -q SPEC_ORIGINAL project.yml; then\n"
            "  printf 'cleanup changed the target\\n' > Sources/Target.swift\nfi\ncp project.yml Generated.txt"))
        config = {"name": "config", "edits": [
            {"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_MUTATED"},
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL"}]}
        result, out, runs = run_runner(root, repo, tools, [config])
        assert result.returncode == 2 and "copy was not restored" in result.stderr, (result.returncode, result.stderr)
        assert len(runs) == 2, runs
        report = json.loads((out / "results.json").read_text())
        assert report["mutants"] == [] and not report["complete"] and report["exit"] == 2, "cleanup failure received a trusted verdict"

    def a_differently_cased_alias_is_the_same_file(root):
        repo, tools = make_repo(root)
        if not ignores_case(repo):
            return  # only a case-insensitive volume can alias a path by case
        aliased = {"name": "aliased", "edits": [
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL MARK"},
            {"path": "sources/target.swift", "old": "MARK", "new": "SECOND"}]}
        result, out, runs = run_runner(root, repo, tools, [aliased])
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert [r[0] for r in runs] == ["let value = ORIGINAL", "let value = KILL SECOND"], runs
        assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n"
        repeated = {"name": "repeated", "edits": [
            {"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "KILL"},
            {"path": "sources/target.swift", "old": "ORIGINAL", "new": "SURVIVOR"}]}
        result, _, runs = run_runner(root, repo, tools, [repeated])
        assert result.returncode == 2 and "occurs 0 times" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def a_test_tool_that_cannot_start_is_reported(root):
        repo, tools = make_repo(root)
        (tools / "xcodebuild").unlink()
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "Traceback" not in result.stderr and "error:" in result.stderr, (
            result.returncode, result.stderr)

    def case_aliased_paths_do_not_escape_the_checks(root):
        repo, tools = make_repo(root)
        if not ignores_case(root):
            return  # only a case-insensitive volume can alias a path by case
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=root / "REPO" / "scratch")
        assert result.returncode == 2 and "outside the repository" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and not (repo / "scratch").exists()
        outer = root / "outer"
        outer.mkdir()
        subprocess.run(["git", "-C", str(outer), "init", "-q"], check=True)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=root / "OUTER" / "out")
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert (out / "copy" / "Sources" / "Dirty.swift").read_text() == "uncommitted\n"

    def overlapping_matches_are_ambiguous(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // aaa\n")
        result, _, runs = run_runner(root, repo, tools, [{"name": "overlap", "edits": [
            {"path": "Sources/Target.swift", "old": "aa", "new": "KILL"}]}])
        assert result.returncode == 2 and "occurs 2 times" in result.stderr, (result.returncode, result.stderr)
        assert runs == [], runs

    def a_refusal_over_a_symlinked_child_still_clears_old_results(root):
        repo, tools = make_repo(root)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0 and (out / "results.json").exists(), result.stderr
        elsewhere = root / "elsewhere"
        elsewhere.mkdir()
        shutil.rmtree(out / "logs")
        (out / "logs").symlink_to(elsewhere)
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        assert result.returncode == 2 and "is a symlink" in result.stderr, (result.returncode, result.stderr)
        assert not (out / "results.json").exists(), "an earlier run's results survived a refusal"

    def a_file_deleted_in_the_working_tree_is_absent_from_the_copy(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Gone.swift").write_text("tracked\n")
        subprocess.run(["git", "-C", str(repo), "add", "Sources/Gone.swift"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "gone"],
                       check=True)
        (repo / "Sources" / "Gone.swift").unlink()
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert not (out / "copy" / "Sources" / "Gone.swift").exists(), "a deleted file came back from HEAD"
        assert (out / "copy" / "Sources" / "Dirty.swift").read_text() == "uncommitted\n"

    def a_signal_before_the_test_tool_starts_stops_it_at_once(root):
        repo, tools = make_repo(root)
        config = {"name": "config", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_PRELAUNCH"}]}
        result, out, runs = run_runner(root, repo, tools, [config])
        assert result.returncode == 2 and "interrupted" in result.stderr, (result.returncode, result.stderr)
        assert not any(r[0] == "finished" for r in runs), f"the test tool ran to completion after the signal: {runs}"
        assert (out / "copy" / "project.yml").read_text() == "name: SPEC_ORIGINAL\n"

    def an_output_directory_holding_the_repository_is_refused(root):
        repo, tools = make_repo(root)
        owned = root / "owned"
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=owned)
        assert result.returncode == 0, result.stderr
        nested_root = owned / "copy" / "nested"
        nested_root.mkdir()
        nested, nested_tools = make_repo(nested_root)
        result, _, runs = run_runner(nested_root, nested, nested_tools, [mutant("kill", "KILL")], out=owned)
        assert result.returncode == 2 and "must not contain the repository" in result.stderr, (
            result.returncode, result.stderr)
        assert runs == [] and (nested / ".git").is_dir() and (nested / "Sources" / "Target.swift").exists()

    def a_selector_that_runs_nothing_beside_one_that_does_refuses(root):
        repo, tools = make_repo(root)
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")],
                                     tests=("ClipboardTTSAppTests/ASuite", "ClipboardTTSAppTests/NopeSuite"))
        assert result.returncode == 2 and "ran no test for ClipboardTTSAppTests/NopeSuite" in result.stderr, (
            result.returncode, result.stderr)
        assert len(runs) == 1, runs

    def a_selector_whose_every_test_skipped_refuses(root):
        repo, tools = make_repo(root)
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")],
                                  tests=("ClipboardTTSAppTests/ASuite", "ClipboardTTSAppTests/SkippedSuite"))
        assert result.returncode == 2 and "ran no test for ClipboardTTSAppTests/SkippedSuite" in result.stderr, (
            result.returncode, result.stderr)

    def a_file_removed_from_the_index_but_left_on_disk_is_not_copied(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Secret.swift").write_text("committed\n")
        subprocess.run(["git", "-C", str(repo), "add", "Sources/Secret.swift"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "secret"],
                       check=True)
        subprocess.run(["git", "-C", str(repo), "rm", "-q", "--cached", "Sources/Secret.swift"], check=True)
        (repo / "Sources" / "Secret.swift").write_text("private, now ignored\n")
        with open(repo / ".gitignore", "a") as ignore:
            ignore.write("Sources/Secret.swift\n")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        secret = out / "copy" / "Sources" / "Secret.swift"
        assert not secret.exists(), f"a file no longer in the index entered the copy: {secret.read_text()!r}"

    def a_case_only_rename_survives_the_copy(root):
        repo, tools = make_repo(root)
        if not ignores_case(repo):
            return  # only a case-insensitive volume names both spellings as one file
        renames = (("rename", "Rename"), ("Upper", "upper"))
        for before, _ in renames:
            (repo / "Sources" / f"{before}.swift").write_text(f"{before}\n")
            subprocess.run(["git", "-C", str(repo), "add", f"Sources/{before}.swift"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "renames"],
                       check=True)
        for before, after in renames:  # both directions staged at once, as Git lists them in either order
            subprocess.run(["git", "-C", str(repo), "mv", f"Sources/{before}.swift", f"Sources/{after}.swift"], check=True)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        names = sorted(p.name for p in (out / "copy" / "Sources").iterdir())
        assert "Rename.swift" in names and "upper.swift" in names, names
        assert (out / "copy" / "Sources" / "Rename.swift").read_text() == "rename\n"

    def unrepresentable_text_refuses_before_building(root):
        repo, tools = make_repo(root)
        for kwargs, where in [
            ({"tests": ("ClipboardTTSAppTests/A\x00B",)}, "a test selector"),
            ({"tests": ("ClipboardTTSAppTests/A\ud800",)}, "a test selector"),
            ({"untracked": ("Tests/New\x00.swift",)}, "an untracked path"),
            ({"mutants": [{"name": "nul", "edits": [{"path": "Sources/Target\x00.swift", "old": "ORIGINAL", "new": "X"}]}]},
             "edit path"),
            ({"mutants": [{"name": "nul", "edits": [{"path": "Sources/Target.swift", "old": "ORIG\x00", "new": "X"}]}]},
             "edit old"),
            ({"mutants": [{"name": "surrogate", "edits": [{"path": "Sources/Target.swift", "old": "ORIGINAL", "new": "\ud800"}]}]},
             "edit new"),
        ]:
            mutants = kwargs.pop("mutants", [mutant("kill", "KILL")])
            result, _, runs = run_runner(root, repo, tools, mutants, **kwargs)
            assert result.returncode == 2 and "cannot be represented" in result.stderr and where in result.stderr, (
                where, result.returncode, result.stderr)
            assert "Traceback" not in result.stderr and runs == [], (where, result.stderr, runs)

    def a_tracked_directory_replaced_by_a_symlink_is_not_followed(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Nested" / "Deep").mkdir(parents=True)
        (repo / "Sources" / "Nested" / "Deep" / "Inner.swift").write_text("tracked\n")
        (repo / "Sources" / "Nested" / "Top.swift").write_text("tracked\n")
        subprocess.run(["git", "-C", str(repo), "add", "Sources/Nested"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "nested"],
                       check=True)
        outside = root / "outside"
        (outside / "Deep").mkdir(parents=True)
        (outside / "Deep" / "Inner.swift").write_text("outside content\n")
        (outside / "Top.swift").write_text("outside content\n")  # the symlink is this file's own parent
        shutil.rmtree(repo / "Sources" / "Nested")
        (repo / "Sources" / "Nested").symlink_to(outside)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        for inner in (out / "copy" / "Sources" / "Nested" / "Deep" / "Inner.swift", out / "copy" / "Sources" / "Nested" / "Top.swift"):
            assert not inner.exists(), f"content from beyond a symlink entered the copy: {inner.read_text()!r}"

    def a_control_that_fails_without_naming_a_test_refuses(root):
        # A crash between tests, or a log cut short, is no passing baseline even though a test started.
        for marker in ("CRASH", "PARTIAL"):
            repo, tools = make_repo(root / marker, f"let value = ORIGINAL // {marker}\n")
            result, _, runs = run_runner(root / marker, repo, tools, [mutant("kill", "KILL")])
            assert result.returncode == 2 and "control did not pass" in result.stderr, (marker, result.returncode,
                                                                                        result.stderr)
            assert len(runs) == 1, (marker, runs)

    def a_changed_symlink_is_copied_as_a_link_not_followed(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Links").mkdir()  # a new directory, which the copy must create for the link
        (repo / "Sources" / "Links" / "Link.swift").symlink_to("../../ignored.log")
        subprocess.run(["git", "-C", str(repo), "add", "Sources/Links/Link.swift"], check=True)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        link = out / "copy" / "Sources" / "Links" / "Link.swift"
        assert link.is_symlink() and os.readlink(link) == "../../ignored.log", "a staged symlink's target entered the copy"

    def a_directory_replaced_by_a_file_becomes_that_file(root):
        repo, tools = make_repo(root)
        (repo / "Sources" / "Mode").mkdir()
        (repo / "Sources" / "Mode" / "a.swift").write_text("tracked\n")
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        git("add", "Sources/Mode/a.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "mode")
        git("rm", "-rq", "Sources/Mode")
        (repo / "Sources" / "Mode").write_text("now a file\n")
        git("add", "Sources/Mode")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        mode = out / "copy" / "Sources" / "Mode"
        assert mode.is_file() and mode.read_text() == "now a file\n", sorted(p.name for p in mode.iterdir())

    def a_generation_failure_reports_the_generator_message(root):
        repo, tools = make_repo(root)
        broken = {"name": "broken", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_BROKEN"}]}
        result, out, _ = run_runner(root, repo, tools, [broken])
        assert result.returncode == 2 and "SPEC_BROKEN is not a valid spec" in result.stderr, (result.returncode,
                                                                                              result.stderr)
        assert (out / "copy" / "project.yml").read_text() == "name: SPEC_ORIGINAL\n"

    def a_staged_rename_leaves_no_old_path(root):
        repo, tools = make_repo(root)
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        (repo / "Sources" / "Old.swift").write_text("renamed\n")
        git("add", "Sources/Old.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "old")
        (repo / "Sources" / "Moved").mkdir()  # a new directory, which the copy must create for the file
        git("mv", "Sources/Old.swift", "Sources/Moved/New.swift")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert not (out / "copy" / "Sources" / "Old.swift").exists(), "a renamed file's old path stayed in the copy"
        assert (out / "copy" / "Sources" / "Moved" / "New.swift").read_text() == "renamed\n"

    def a_rerun_rebuilds_the_copy_from_the_current_target(root):
        repo, tools = make_repo(root)
        (repo / "Tests" / "Extra.swift").write_text("extra\n")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], untracked=("Tests/New.swift", "Tests/Extra.swift"))
        assert result.returncode == 0 and (out / "copy" / "Tests" / "Extra.swift").exists(), result.stderr
        result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        assert result.returncode == 0, result.stderr
        assert not (out / "copy" / "Tests" / "Extra.swift").exists(), "an earlier run's file stayed in the copy"

    def a_tracked_symlink_replaced_by_a_file_is_not_written_through(root):
        repo, tools = make_repo(root)
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        (repo / "Sources" / "Link.swift").symlink_to("../../victim.txt")  # dangling, and outside the copy
        git("add", "Sources/Link.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "link")
        (repo / "Sources" / "Link.swift").unlink()
        (repo / "Sources" / "Link.swift").write_text("now a file\n")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        link = out / "copy" / "Sources" / "Link.swift"
        assert not link.is_symlink() and link.read_text() == "now a file\n", "the copy kept the symlink"
        assert not (out / "victim.txt").exists() and not (root / "victim.txt").exists(), "a write went through the link"

    def an_output_path_that_is_a_file_refuses(root):
        repo, tools = make_repo(root)
        out = root / "out-file"
        out.write_text("keep\n")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        assert result.returncode == 2 and "is not a directory" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and out.read_text() == "keep\n"

    def a_signal_during_the_control_stops_it(root):
        for marker, signal_name in (("INTERRUPT", "SIGTERM"), ("CTRLC", "SIGINT")):
            repo, tools = make_repo(root / marker, f"let value = ORIGINAL // {marker}\n")
            result, _, runs = run_runner(root / marker, repo, tools, [mutant("kill", "KILL")],
                                         ignore_sigint=marker == "CTRLC")
            assert result.returncode == 2 and "interrupted" in result.stderr, (signal_name, result.returncode, result.stderr)
            assert len(runs) == 1 and runs[0][0] != "finished", (signal_name, runs)

    def a_runner_outside_a_repository_refuses(root):
        (root / "loose").mkdir()
        runner = root / "loose" / "run-mutants.py"
        runner.write_text(RUNNER.read_text())
        spec = root / "spec.json"
        spec.write_text(json.dumps({"mutants": [mutant("kill", "KILL")]}))
        result = subprocess.run([sys.executable, str(runner), str(spec), "--out", str(root / "out")],
                                capture_output=True, text=True, timeout=60, env=dict(os.environ, GIT_CEILING_DIRECTORIES=str(root)))
        assert result.returncode == 2 and "Traceback" not in result.stderr and "error:" in result.stderr, (
            result.returncode, result.stderr)

    def paths_git_quotes_reach_the_copy(root):
        # Without -z, Git quotes these names in its listings, so they would match no path on disk.
        repo, tools = make_repo(root)
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        (repo / "Sources" / "Café.swift").write_text("committed\n")
        git("add", "Sources/Café.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "cafe")
        (repo / "Sources" / "Café.swift").write_text("modified\n")
        (repo / "Sources" / "Naïve.swift").write_text("staged\n")
        git("add", "Sources/Naïve.swift")
        (repo / "Tests" / "Été.swift").write_text("untracked\n")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], untracked=("Tests/New.swift", "Tests/Été.swift"))
        assert result.returncode == 0, (result.returncode, result.stderr)
        copy = out / "copy"
        assert (copy / "Sources" / "Café.swift").read_text() == "modified\n", "a changed quoted path kept HEAD's content"
        assert (copy / "Sources" / "Naïve.swift").read_text() == "staged\n", "a staged quoted path is missing"
        assert (copy / "Tests" / "Été.swift").read_text() == "untracked\n"

    def an_empty_or_new_nested_output_directory_is_accepted(root):
        repo, tools = make_repo(root)
        (root / "empty").mkdir()
        for out in (root / "empty", root / "new" / "nested" / "out"):
            result, _, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
            assert result.returncode == 0, (out, result.returncode, result.stderr)

    def a_mutant_that_skips_a_selected_test_is_unjudged(root):
        # The control ran both selectors; a mutant that makes one of them skip says nothing through it.
        repo, tools = make_repo(root)
        tests = ("ClipboardTTSAppTests/ASuite", "ClipboardTTSAppTests/BSuite")
        result, out, _ = run_runner(root, repo, tools, [mutant("skip-b", "SKIP_B"), mutant("kill-skip-b", "KILL SKIP_B")],
                                    tests=tests)
        lines = dict(line.split(":", 1) for line in result.stdout.splitlines())
        assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
        assert lines["skip-b"].strip() == "NO-TESTS no test ran for ClipboardTTSAppTests/BSuite", lines
        assert lines["kill-skip-b"].strip() == "KILLED ClipboardTTSAppTests.ASuite testGuard", lines

    def a_control_that_runs_no_test_refuses(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // NOTESTS\n")
        result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "control did not pass" in result.stderr, (result.returncode, result.stderr)
        assert len(runs) == 1, runs

    def every_indexed_path_is_copied_as_the_working_tree_holds_it(root):
        # Neither HEAD, Git's view of what changed, nor an export attribute may decide the copy.
        repo, tools = make_repo(root)
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        (repo / ".gitattributes").write_text("Sources/Exported.swift export-ignore\nSources/Subst.swift export-subst\n")
        (repo / "Sources" / "Exported.swift").write_text("exported\n")
        (repo / "Sources" / "Subst.swift").write_text("$Format:%H$\n")
        (repo / "Sources" / "Assumed.swift").write_text("committed\n")
        git("add", ".gitattributes", "Sources/Exported.swift", "Sources/Subst.swift", "Sources/Assumed.swift")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "attributes")
        (repo / "Sources" / "Assumed.swift").write_text("edited while Git assumes it unchanged\n")
        git("update-index", "--assume-unchanged", "Sources/Assumed.swift")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        copy = out / "copy" / "Sources"
        assert (copy / "Exported.swift").read_text() == "exported\n", "an export-ignored file left the copy"
        assert (copy / "Subst.swift").read_text() == "$Format:%H$\n", "an export substitution reached the copy"
        assert (copy / "Assumed.swift").read_text() == "edited while Git assumes it unchanged\n", "HEAD's content was copied"

    def a_tracked_submodule_is_refused(root):
        repo, tools = make_repo(root)
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True)
        head = git("rev-parse", "HEAD").stdout.strip()
        git("update-index", "--add", "--cacheinfo", f"160000,{head},Sources/Sub")
        git("-c", "user.name=v", "-c", "user.email=v@v", "commit", "-qm", "submodule")
        (repo / "Sources" / "Sub").mkdir()  # as an uninitialized submodule leaves it
        (repo / "Sources" / "Sub" / "Inner.swift").write_text("another repository's file\n")
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 2 and "neither a file nor a symlink" in result.stderr, (result.returncode, result.stderr)
        assert runs == [] and not (out / "copy" / "Sources" / "Sub" / "Inner.swift").exists(), runs

    def an_unmerged_path_is_copied_once(root):
        # The index lists an unmerged path once per stage; the working tree holds one entry for it.
        repo, tools = make_repo(root)
        git = lambda *a, **k: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True, **k)
        blob = git("hash-object", "-w", "--stdin", input="Target.swift").stdout.strip()
        git("update-index", "--index-info",
            input="".join(f"120000 {blob} {stage}\tSources/Conflict.swift\n" for stage in (1, 2, 3)))
        (repo / "Sources" / "Conflict.swift").symlink_to("Target.swift")
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")])
        assert result.returncode == 0, (result.returncode, result.stderr)
        link = out / "copy" / "Sources" / "Conflict.swift"
        assert link.is_symlink() and os.readlink(link) == "Target.swift", "an unmerged path did not reach the copy"

    def interrupted_by_a_terminal_during_generation(root, marker):
        repo, tools = make_repo(root)
        config = {"name": "config", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": marker}]}
        result, out, runs = run_runner(root, repo, tools, [config, mutant("later", "KILL")], own_session=True)
        assert result.returncode == 2 and "interrupted by signal 2; the copy was restored" in result.stderr, (
            result.returncode, result.stderr)
        for path in ("project.yml", "Generated.txt"):
            assert (out / "copy" / path).read_text() == "name: SPEC_ORIGINAL\n", f"{path} was left mutated"
        assert not any(r[0] == "let value = KILL" for r in runs), f"a mutant ran after the interrupt: {runs}"
        report = json.loads((out / "results.json").read_text())
        assert not report["complete"] and report["exit"] == 2 and report["mutants"] == [], report

    def a_terminal_interrupt_during_generation_before_a_test_run_lets_it_finish(root):
        interrupted_by_a_terminal_during_generation(root, "SPEC_CTRLC_BEFORE")

    def a_terminal_interrupt_during_regeneration_after_a_restore_lets_it_finish(root):
        interrupted_by_a_terminal_during_generation(root, "SPEC_CTRLC_AFTER")

    def a_terminal_interrupt_during_the_architecture_query_is_an_interrupt(root):
        repo, tools = make_repo(root)
        (root / "bin").mkdir()
        # Unlike the shell stand-ins, which cannot undo a SIGINT they inherit as ignored, this one takes the
        # default action back, as a tool that handles Ctrl-C itself would, so only its process group shields it.
        (root / "bin" / "uname").write_text(
            f"#!{sys.executable}\nimport os, signal, sys\nsignal.signal(signal.SIGINT, signal.SIG_DFL)\n"
            "os.killpg(os.getpgid(os.getppid()), signal.SIGINT)\nos.execv('/usr/bin/uname', ['uname', *sys.argv[1:]])\n")
        (root / "bin" / "uname").chmod(0o755)
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], own_session=True,
                                       env={"PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}"})
        assert result.returncode == 2 and "error: interrupted by signal 2" in result.stderr, (result.returncode, result.stderr)
        assert not any(r[0] == "let value = KILL" for r in runs), f"a mutant ran after the interrupt: {runs}"
        assert not json.loads((out / "results.json").read_text())["complete"]

    def a_terminal_signal_still_reaches_the_test_tool(root):
        # The test tool stays in the runner's process group: a terminal's Ctrl-C ends it as the runner's own
        # stop does, and a hangup, which the runner does not handle, cannot leave it running without the runner.
        repo, tools = make_repo(root / "int")
        result, out, runs = run_runner(root / "int", repo, tools, [mutant("groupint", "GROUPINT"), mutant("later", "KILL")],
                                       own_session=True)
        assert result.returncode == 2 and "interrupted by signal 2; the copy was restored" in result.stderr, (
            result.returncode, result.stderr)
        assert [r[0] for r in runs] == ["let value = ORIGINAL", "let value = GROUPINT"], f"the test tool was not stopped: {runs}"
        assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n"
        repo, tools = make_repo(root / "hup", "let value = ORIGINAL // HANGUP\n")
        result, _, runs = run_runner(root / "hup", repo, tools, [mutant("kill", "KILL")], own_session=True)
        assert result.returncode == -signal.SIGHUP, (result.returncode, result.stderr)
        pid = next(r[1] for r in runs if r[0] == "hanging up")
        for _ in range(200):  # wait for the tool to be gone, which ends at once unless it outlived the hangup
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        record = [ast.literal_eval(line) for line in (root / "hup" / "record.txt").read_text().splitlines()]
        assert not any(r[0] == "outlived the hangup" for r in record), f"the test tool outlived the runner: {record}"

    def a_failed_regeneration_after_a_restore_stops_the_run(root):
        repo, tools = make_repo(root)
        config = {"name": "config", "edits": [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_REGEN_FAILS"}]}
        result, out, runs = run_runner(root, repo, tools, [config, mutant("later", "KILL")])
        assert result.returncode == 2 and "cannot regenerate over SPEC_REGEN_FAILS" in result.stderr, (
            result.returncode, result.stderr)
        assert "config:" not in result.stdout and len(runs) == 2, f"the run went on: {result.stdout} {runs}"
        report = json.loads((out / "results.json").read_text())
        assert not report["complete"] and report["exit"] == 2 and report["mutants"] == [], report
        assert "cannot regenerate over SPEC_REGEN_FAILS" in report["error"], report

    def gone(pid):
        """Whether pid has exited, allowing a moment for one that is still exiting."""
        for _ in range(100):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.05)
        return False

    def all_gone(pids):
        """Whether every one of a case's stand-ins has exited; any still running is killed, being that case's own."""
        survivors = [pid for pid in pids if not gone(pid)]
        for pid in survivors:
            os.kill(pid, signal.SIGKILL)
        return not survivors

    def a_test_run_past_its_deadline_is_stopped_and_left_unjudged(root):
        repo, tools = make_repo(root)
        result, out, runs = run_runner(root, repo, tools, [mutant("stall", "STALL"), mutant("later", "KILL")],
                                       extra=("--test-deadline", "2.5"))
        lines = dict(line.split(":", 1) for line in result.stdout.splitlines())
        detail = "the test run did not finish within 2.5 seconds and was stopped"
        assert result.returncode == 1, f"a stopped mutant is unjudged: {result.returncode}: {result.stderr}"
        assert lines["stall"].strip() == f"NO-VERDICT {detail}", lines
        assert lines["later"].strip() == "KILLED ClipboardTTSAppTests.ASuite testGuard", f"the campaign stopped: {lines}"
        pid = next(r[1] for r in runs if r[0] == "stalling")
        assert ("stopped", pid) in runs, f"the test tool was not asked to stop before it was killed: {runs}"
        assert gone(pid) and not any(r[0] == "outlived the runner" for r in runs), runs
        assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n"
        report = json.loads((out / "results.json").read_text())
        assert report["complete"] and report["exit"] == 1 and report["mutants"][0] == {
            "name": "stall", "verdict": "NO-VERDICT", "details": [detail]}, report
        assert report["deadlines"] == {"test_run": 2.5, "short_tool": 60}, report

    def a_test_run_that_ignores_the_stop_is_killed_and_left_unjudged(root):
        # It has already printed a success, but the deadline, not the tests, ended it.
        repo, tools = make_repo(root)
        # Python's own warnings are on, so a killed tool the runner never reaped says so on stderr.
        result, out, runs = run_runner(root, repo, tools, [mutant("stubborn", "STUBBORN")],
                                       extra=("--test-deadline", "2", "--tool-deadline", "2"),
                                       env={"PYTHONWARNINGS": "default"})
        assert result.returncode == 1, (result.returncode, result.stderr)
        assert result.stderr == "", f"the killed test tool was not reaped cleanly: {result.stderr}"
        assert "stubborn: NO-VERDICT the test run did not finish within 2 seconds" in result.stdout, result.stdout
        pid = next(r[1] for r in runs if r[0] == "stalling")
        record = [ast.literal_eval(line) for line in (root / "record.txt").read_text().splitlines()]
        assert gone(pid) and not any(r[0] == "outlived the runner" for r in record), record
        assert (out / "copy" / "Sources" / "Target.swift").read_text() == "let value = ORIGINAL\n"

    def a_control_past_its_deadline_refuses(root):
        repo, tools = make_repo(root, "let value = ORIGINAL // STALL\n")
        result, out, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], extra=("--test-deadline", "2"))
        assert result.returncode == 2 and "control did not pass" in result.stderr, (result.returncode, result.stderr)
        assert "control: NO-VERDICT the test run did not finish within 2 seconds and was stopped" in result.stdout
        assert not any(r[0] == "let value = KILL" for r in runs), runs
        report = json.loads((out / "results.json").read_text())
        assert report["control"]["verdict"] == "NO-VERDICT" and report["mutants"] == [], report

    def a_test_run_within_its_deadline_is_judged(root):
        # It outlasts the short tools' deadline, which bounds only them and the wait for a stopped test tool.
        repo, tools = make_repo(root)
        result, _, _ = run_runner(root, repo, tools, [mutant("slow", "SLOW")],
                                  extra=("--test-deadline", "30", "--tool-deadline", "1.5"))
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        assert "slow: KILLED ClipboardTTSAppTests.ASuite testGuard" in result.stdout, result.stdout

    def a_short_tool_past_its_deadline_is_killed_with_its_session_and_stops_the_run(root):
        # XcodeGen before a mutant's test run and after its restore, and uname: none hears a terminal's Ctrl-C.
        for site in ("SPEC_STALL_BEFORE", "SPEC_STALL_AFTER", "uname"):
            base = root / site
            repo, tools = make_repo(base)
            env = None
            if site == "uname":
                (base / "bin").mkdir()
                (base / "bin" / "uname").write_text(f"#!/bin/sh\nexec '{tools / 'stall'}'\n")
                (base / "bin" / "uname").chmod(0o755)
                env = {"PATH": f"{base / 'bin'}{os.pathsep}{os.environ['PATH']}"}
            edits = [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": site}]
            result, out, runs = run_runner(base, repo, tools, [{"name": "config", "edits": edits}, mutant("later", "KILL")],
                                           extra=("--tool-deadline", "2"), env=env)
            assert result.returncode == 2, (site, result.returncode, result.stderr)
            assert "did not finish within 2 seconds and was stopped\n" in result.stderr, (site, result.stderr)
            assert "Traceback" not in result.stderr and "config:" not in result.stdout, (site, result.stdout, result.stderr)
            assert not any(r[0] == "let value = KILL" for r in runs), (site, runs)
            pids = [r[2] for r in runs if r[0] == "stalling"]
            assert sorted(r[1] for r in runs if r[0] == "stalling") == ["helper", "tool"], (site, runs)
            assert all_gone(pids), (site, runs)
            record = [ast.literal_eval(line) for line in (base / "record.txt").read_text().splitlines()]
            assert not any(r[0] == "outlived what started it" for r in record), (site, record)
            assert (out / "copy" / "project.yml").read_text() == "name: SPEC_ORIGINAL\n", site
            report = json.loads((out / "results.json").read_text())
            assert not report["complete"] and report["exit"] == 2 and report["mutants"] == [], (site, report)

    def a_short_tool_whose_output_outlives_it_is_stopped_at_its_deadline(root):
        # The tool has finished, so its session holds nothing left to kill, and the stop must still end the wait.
        repo, tools = make_repo(root)
        (root / "bin").mkdir()
        (root / "bin" / "uname").write_text(
            f"#!{sys.executable}\nimport subprocess, sys\n"
            f"subprocess.Popen([sys.executable, {str(tools / 'stall')!r}, 'holder'], start_new_session=True)\n")
        (root / "bin" / "uname").chmod(0o755)
        release = root / "release"
        try:
            result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], extra=("--tool-deadline", "2"),
                                         env={"PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}",
                                              "RUNNER_VERIFY_RELEASE": str(release)})
        finally:
            release.write_text("")
        assert result.returncode == 2 and "error: uname -m did not finish within 2 seconds and was stopped" in result.stderr, (
            result.returncode, result.stderr)
        assert "Traceback" not in result.stderr and runs[0][:2] == ("stalling", "holder"), (result.stderr, runs)
        assert gone(runs[0][2]), runs

    def a_member_that_forks_while_the_session_is_listed_is_killed_too(root):
        # A ps placed first on PATH holds the runner's first listing until the helper has started a late member,
        # which that listing therefore misses.
        repo, tools = make_repo(root)
        fork, record = root / "fork", root / "record.txt"
        (root / "bin").mkdir()
        (root / "bin" / "ps").write_text(
            "#!/bin/sh\nlisting=$(/bin/ps \"$@\")\n"
            f"if [ ! -e '{fork}' ]; then\n  touch '{fork}'\n"
            f"  until grep -q \"'late'\" '{record}'; do sleep 0.05; done\nfi\nprintf '%s\\n' \"$listing\"\n")
        (root / "bin" / "ps").chmod(0o755)
        edits = [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_STALL_BEFORE"}]
        result, _, runs = run_runner(root, repo, tools, [{"name": "config", "edits": edits}], extra=("--tool-deadline", "2"),
                                     env={"PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}",
                                          "RUNNER_VERIFY_FORK": str(fork)})
        assert result.returncode == 2 and "did not finish within 2 seconds" in result.stderr, (result.returncode, result.stderr)
        roles = sorted(r[1] for r in runs if r[0] == "stalling")
        assert roles == ["helper", "late", "tool"], f"the late member never started: {runs}"
        assert all_gone([r[2] for r in runs if r[0] == "stalling"]), f"a member outlived the stop: {runs}"

    def a_session_that_cannot_be_listed_in_time_still_stops_the_run(root):
        # The listing that finds the session's members is bounded by the same deadline: a ps placed first on PATH
        # hangs, fails, or takes longer than what is left of the deadline after one listing.
        stand_ins = {
            "hangs": "while not os.path.exists(release) and time.monotonic() < give_up:\n    time.sleep(0.05)\n",
            "fails": "sys.exit('ps: cannot list processes')\n",
            "slow": "time.sleep(1.5)\nos.execv('/bin/ps', ['ps', *sys.argv[1:]])\n",
        }
        for behavior, body in stand_ins.items():
            base = root / behavior
            repo, tools = make_repo(base)
            (base / "bin").mkdir()
            release = base / "release"
            (base / "bin" / "ps").write_text(
                f"#!{sys.executable}\nimport os, sys, time\nrelease, give_up = {str(release)!r}, time.monotonic() + 60\n" + body)
            (base / "bin" / "ps").chmod(0o755)
            edits = [{"path": "project.yml", "old": "SPEC_ORIGINAL", "new": "SPEC_STALL_BEFORE"}]
            try:
                result, _, runs = run_runner(base, repo, tools, [{"name": "config", "edits": edits}],
                                             extra=("--tool-deadline", "2"),
                                             env={"PATH": f"{base / 'bin'}{os.pathsep}{os.environ['PATH']}",
                                                  "RUNNER_VERIFY_RELEASE": str(release)})
            finally:
                release.write_text("")  # what the runner could not confirm stopped may end now, before this case ends
                recorded = [ast.literal_eval(line) for line in (base / "record.txt").read_text().splitlines()]
                all_gone([r[2] for r in recorded if r[0] == "stalling"])
            assert result.returncode == 2, (behavior, result.returncode, result.stderr)
            assert ("did not finish within 2 seconds and was stopped; not every process in its session could be "
                    "confirmed stopped") in result.stderr, (behavior, result.stderr)
            assert "Traceback" not in result.stderr, (behavior, result.stderr)
            tool = next(r[2] for r in runs if r[:2] == ("stalling", "tool"))
            assert gone(tool), f"{behavior}: the stopped tool itself is still running: {runs}"

    def a_deadline_that_cannot_bound_a_run_is_refused(root):
        repo, tools = make_repo(root)
        for option in ("--test-deadline", "--tool-deadline"):
            for value in ("0", "-1", "nan", "inf", "soon"):
                result, _, runs = run_runner(root, repo, tools, [mutant("kill", "KILL")], extra=(option, value))
                assert result.returncode == 2 and option in result.stderr, (option, value, result.returncode, result.stderr)
                assert "Traceback" not in result.stderr and runs == [], (option, value, result.stderr, runs)
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], extra=("--tool-deadline", "7.5"))
        report = json.loads((out / "results.json").read_text())
        assert result.returncode == 0 and report["deadlines"] == {"test_run": 1800, "short_tool": 7.5}, report
        result, out, _ = run_runner(root, repo, tools, [mutant("kill", "KILL")], out=out)
        report = json.loads((out / "results.json").read_text())
        assert report["deadlines"] == {"test_run": 1800, "short_tool": 60}, f"the documented deadlines are not the defaults: {report}"

    checks = (verdicts_and_restore, every_judged_verdict_exits_zero, omitted_tests_and_untracked_take_their_defaults,
              results_identify_their_run, a_second_run_on_a_directory_in_use_is_refused,
              a_mutant_of_two_files_is_tested_and_restored_whole, only_selects, interrupted_run_restores, failing_control_refuses,
              ambiguous_edit_refuses_before_building, missing_edit_refuses_before_building,
              out_inside_repository_refuses, ignored_file_cannot_be_named, malformed_specs_refuse,
              edit_paths_stay_inside_the_copy, edits_apply_in_order_as_specified, a_mutant_that_runs_no_test_is_unjudged,
              every_test_selector_is_passed, an_unknown_only_name_refuses,
              untracked_files_are_copied_as_named_and_never_through_a_symlink,
              the_tracked_diff_applies_inside_an_unrelated_repository, unknown_spec_keys_refuse,
              a_refused_run_leaves_no_earlier_evidence, generated_files_are_rebuilt_after_a_restore,
              a_foreign_output_directory_is_left_alone, a_symlinked_child_is_never_written_through,
              an_interrupt_during_cleanup_waits_for_it, a_generated_file_is_not_an_edit_target,
              generation_cannot_erase_a_tracked_mutant_before_testing, edits_and_restore_preserve_exact_line_endings,
              restoration_is_checked_after_regeneration,
              a_differently_cased_alias_is_the_same_file, a_test_tool_that_cannot_start_is_reported,
              case_aliased_paths_do_not_escape_the_checks, overlapping_matches_are_ambiguous,
              a_refusal_over_a_symlinked_child_still_clears_old_results,
              a_file_deleted_in_the_working_tree_is_absent_from_the_copy,
              a_signal_before_the_test_tool_starts_stops_it_at_once,
              an_output_directory_holding_the_repository_is_refused,
              a_selector_that_runs_nothing_beside_one_that_does_refuses,
              a_tracked_directory_replaced_by_a_symlink_is_not_followed, a_selector_whose_every_test_skipped_refuses,
              unrepresentable_text_refuses_before_building, a_file_removed_from_the_index_but_left_on_disk_is_not_copied,
              a_case_only_rename_survives_the_copy,
              a_control_that_runs_no_test_refuses, a_control_that_fails_without_naming_a_test_refuses,
              a_changed_symlink_is_copied_as_a_link_not_followed, a_directory_replaced_by_a_file_becomes_that_file,
              a_generation_failure_reports_the_generator_message, a_symlinked_ownership_marker_is_not_ownership,
              a_tracked_file_replaced_by_a_directory_refuses, a_staged_rename_leaves_no_old_path,
              a_rerun_rebuilds_the_copy_from_the_current_target,
              a_tracked_symlink_replaced_by_a_file_is_not_written_through, an_output_path_that_is_a_file_refuses,
              a_signal_during_the_control_stops_it, a_runner_outside_a_repository_refuses,
              paths_git_quotes_reach_the_copy, an_empty_or_new_nested_output_directory_is_accepted,
              a_mutant_that_skips_a_selected_test_is_unjudged, every_indexed_path_is_copied_as_the_working_tree_holds_it,
              a_tracked_submodule_is_refused, an_unmerged_path_is_copied_once,
              a_terminal_interrupt_during_generation_before_a_test_run_lets_it_finish,
              a_terminal_interrupt_during_regeneration_after_a_restore_lets_it_finish,
              a_terminal_interrupt_during_the_architecture_query_is_an_interrupt,
              a_terminal_signal_still_reaches_the_test_tool, a_failed_regeneration_after_a_restore_stops_the_run,
              a_test_run_past_its_deadline_is_stopped_and_left_unjudged,
              a_test_run_that_ignores_the_stop_is_killed_and_left_unjudged, a_control_past_its_deadline_refuses,
              a_test_run_within_its_deadline_is_judged,
              a_short_tool_past_its_deadline_is_killed_with_its_session_and_stops_the_run,
              a_short_tool_whose_output_outlives_it_is_stopped_at_its_deadline,
              a_member_that_forks_while_the_session_is_listed_is_killed_too,
              a_session_that_cannot_be_listed_in_time_still_stops_the_run,
              a_deadline_that_cannot_bound_a_run_is_refused)
    for check in checks:
        case(check.__name__, check)
    return failures, len(checks)


def main():
    # Fixture repositories must not depend on the developer's Git configuration, such as commit signing or hooks.
    os.environ.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    runner = load_runner()
    failures = []
    for name, log, expected in CLASSIFY_CASES:
        try:
            actual = runner.classify(log)
        except Exception as error:  # a crash is this case's failure, not the whole verifier's
            actual = f"{type(error).__name__}: {error}"
        if actual != expected:
            failures.append(f"classify: {name}: expected {expected}, got {actual}")
    for name, tests, expected in SELECTOR_CASES:
        log = PASSED_ONLY_LOG if tests is None else SELECTOR_LOG
        try:
            actual = runner.selectors_without_tests(log, tests or ["ClipboardTTSAppTests"])
        except Exception as error:  # a crash is this case's failure, not the whole verifier's
            actual = f"{type(error).__name__}: {error}"
        if actual != expected:
            failures.append(f"selectors: {name}: expected {expected}, got {actual}")
    end_to_end_failures, end_to_end_count = end_to_end_cases()
    failures += end_to_end_failures
    total = len(CLASSIFY_CASES) + len(SELECTOR_CASES) + end_to_end_count
    for failure in failures:
        print(f"FAIL {failure}")
    print(f"{total - len(failures)}/{total} cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
