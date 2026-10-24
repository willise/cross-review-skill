"""Offline regression tests; the fake CLI never contacts a model or proxy."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("runner", SCRIPTS / "run-claude-review.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

FAKE_CLAUDE = '''#!/usr/bin/env python3
import json, os, signal, sys
from pathlib import Path
args = sys.argv[1:]
resume = "--resume" in args
sid = args[args.index("--resume" if resume else "--session-id") + 1]
root = Path(os.environ["REVIEW_TEST_ROOT"])
with (root / "calls.jsonl").open("a") as target:
    target.write(json.dumps({"args": args, "prompt": sys.stdin.read()}) + "\\n")
mode = os.environ["REVIEW_TEST_MODE"]
print(json.dumps({"type": "system", "subtype": "init", "session_id": sid}), flush=True)
print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "still reviewing"}]}}), flush=True)
if mode == "double_timeout" or (mode.startswith("timeout") and not resume):
    signal.pause()
if mode == "initial_error" or (mode == "timeout_resume_error" and resume):
    sys.exit(7)
if mode == "partial_only":
    sys.exit(0)
result = {"type": "result", "subtype": "success", "is_error": False,
          "session_id": sid, "result": "Final assessment; incomplete coverage disclosed."}
if mode == "terminal_error":
    result.update(subtype="error_during_execution", is_error=True)
if mode == "wrong_session":
    result["session_id"] = "another-session"
print(json.dumps(result), flush=True)
'''


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cross-review-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / "sample.py").write_text("print('review fixture')\n")
        fake = self.root / "claude"
        fake.write_text(FAKE_CLAUDE)
        fake.chmod(0o755)
        self.out = self.root / "output"

    def invoke(self, mode, *extra):
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                   REVIEW_TEST_ROOT=str(self.root), REVIEW_TEST_MODE=mode)
        return subprocess.run(
            ["bash", str(SCRIPTS / "run-cross-review.sh"), "--repo", str(self.repo),
             "--path", "sample.py", "--reviewer", "claude", "--output-dir", "output",
             *extra], cwd=self.root, env=env, capture_output=True, text=True, timeout=15,
        )

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def summary(self):
        return dict(line.split("=", 1) for line in (self.out / "run-summary.txt").read_text().splitlines())

    def test_normal_completion_defaults_and_relative_output(self):
        result = self.invoke("normal")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.summary()["timeout_seconds"], "900")
        self.assertEqual(self.summary()["resume_timeout_seconds"], "300")
        self.assertEqual(self.summary()["resume_attempted"], "0")
        command = self.calls()[0]["args"]
        self.assertEqual(command[command.index("--model") + 1], "claude-opus-5-5")
        self.assertEqual(command[command.index("--effort") + 1], "high")
        self.assertEqual(self.summary()["claude_model"], "claude-opus-5-5")
        self.assertEqual(self.summary()["claude_effort"], "high")
        self.assertIn("Final assessment", (self.out / "assessment.md").read_text())
        self.assertIn("still reviewing", (self.out / "claude-events.jsonl").read_text())
        self.assertNotIn("still reviewing", (self.out / "assessment.md").read_text())

    def test_timeout_resumes_exact_session_and_same_model_once(self):
        result = self.invoke("timeout_then_success", "--timeout-seconds", "1", "--resume-timeout-seconds", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        first, last = self.calls()
        initial, resumed = first["args"], last["args"]
        sid = initial[initial.index("--session-id") + 1]
        self.assertEqual(resumed[resumed.index("--resume") + 1], sid)
        self.assertEqual((self.out / "claude-session-id.txt").read_text().strip(), sid)
        self.assertEqual(initial[initial.index("--model") + 1], resumed[resumed.index("--model") + 1])
        self.assertEqual(resumed[resumed.index("--model") + 1], "claude-opus-5-5")
        self.assertNotIn("--continue", resumed)
        self.assertNotIn("--fork-session", resumed)
        self.assertEqual(resumed[resumed.index("--tools") + 1], "")
        self.assertIn("--strict-mcp-config", resumed)
        self.assertEqual(last["prompt"], RUNNER.WRAP_UP)
        self.assertNotIn("Diff Snapshot", last["prompt"])
        self.assertEqual(self.summary()["initial_exit"], "124")
        self.assertEqual(self.summary()["resume_exit"], "0")
        self.assertTrue((self.out / "claude-resume-events.jsonl").exists())

    def test_double_timeout_stops_after_one_resume(self):
        result = self.invoke("double_timeout", "--timeout-seconds", "1", "--resume-timeout-seconds", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.summary()["assessment_status"], "timeout")
        self.assertNotIn("Final assessment", (self.out / "assessment.md").read_text())

    def test_resume_error_does_not_restart(self):
        result = self.invoke("timeout_resume_error", "--timeout-seconds", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.summary()["resume_exit"], "7")

    def test_initial_error_is_not_retried(self):
        result = self.invoke("initial_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.summary()["resume_attempted"], "0")

    def test_large_scope_keeps_read_access(self):
        (self.repo / "sample.py").write_text("# fixture\n" * 5000)
        result = self.invoke("normal")
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.calls()[0]["args"]
        self.assertEqual(command[command.index("--tools") + 1], "Read,Grep,Glob")
        self.assertEqual(command[command.index("--allowedTools") + 1], "Read,Grep,Glob")
        self.assertEqual(command[command.index("--permission-mode") + 1], "dontAsk")
        self.assertIn("--strict-mcp-config", command)
        self.assertIn(str(self.repo), command)
        self.assertIn(str(self.out), command)

    def test_reviewer_never_gets_write_capable_permissions(self):
        for size in (1, 5000):
            with self.subTest(size=size):
                (self.repo / "sample.py").write_text("# fixture\n" * size)
                (self.root / "calls.jsonl").exists() and (self.root / "calls.jsonl").unlink()
                self.assertEqual(self.invoke("normal").returncode, 0)
                command = " ".join(self.calls()[0]["args"])
                self.assertNotIn("bypassPermissions", command)
                self.assertNotIn("Bash", command)

    def test_partial_error_and_wrong_session_are_not_success(self):
        for mode in ("partial_only", "terminal_error", "wrong_session"):
            with self.subTest(mode=mode):
                result = self.invoke(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.summary()["resume_attempted"], "0")
                self.assertNotIn("Final assessment", (self.out / "assessment.md").read_text())

    def test_incomplete_json_line_is_not_final_assessment(self):
        events = self.root / "events.jsonl"
        events.write_text('{"type":"assistant"}\n{"type":"result"')
        self.assertIsNone(RUNNER.final_result(events, "session"))

    def test_group_children_are_killed_even_if_leader_exits(self):
        process = mock.Mock(pid=12345)
        with mock.patch.object(RUNNER.os, "killpg") as kill:
            RUNNER.stop_group(process)
        self.assertEqual(kill.call_args_list, [mock.call(12345, signal.SIGTERM), mock.call(12345, signal.SIGKILL)])
        self.assertEqual(process.wait.call_count, 2)

    def test_invalid_time_budget_rejected(self):
        result = self.invoke("normal", "--resume-timeout-seconds", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls.jsonl").exists())


FAKE_CODEX = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
legacy = os.environ.get("CODEX_TEST_LEGACY") == "1"
if args[-1:] == ["--help"]:
    print("--full-auto" if legacy and len(args) == 1 else "")
    print("--json" if len(args) == 2 else "")
    sys.exit(0)
prompt = sys.stdin.read() if args[-1] == "-" else args[-1]
with (Path(os.environ["REVIEW_TEST_ROOT"]) / "codex-calls.jsonl").open("a") as target:
    target.write(json.dumps({"args": args, "prompt": prompt}) + "\\n")
Path(args[args.index("-o") + 1]).write_text("Codex assessment\\n")
print(json.dumps({"type": "event"}))
'''


class HelperTests(unittest.TestCase):
    """Diff collection, eligibility gate, prompt context and Codex sandboxing."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cross-review-helper-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "src").mkdir(parents=True)
        self.git("init", "-q")
        (self.repo / "CLAUDE.md").write_text("Root rule: never log secrets.\n")
        (self.repo / "src" / "AGENTS.md").write_text("Src rule: keep functions pure.\n")
        (self.repo / "src" / "app.py").write_text("x = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "seed app module")
        fake = self.root / "codex"
        fake.write_text(FAKE_CODEX)
        fake.chmod(0o755)
        self.out = self.root / "output"

    def git(self, *args):
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
                       cwd=self.repo, check=True, capture_output=True)

    def run_helper(self, *args, legacy=False):
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                   REVIEW_TEST_ROOT=str(self.root), CODEX_TEST_LEGACY="1" if legacy else "0")
        return subprocess.run(
            ["bash", str(SCRIPTS / "run-cross-review.sh"), "--repo", str(self.repo),
             "--reviewer", "codex", "--output-dir", str(self.out), *args],
            env=env, capture_output=True, text=True, timeout=15,
        )

    def codex_calls(self):
        path = self.root / "codex-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_empty_diff_skips_reviewer(self):
        result = self.run_helper("--staged")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.codex_calls(), [])
        self.assertIn("assessment_status=no_changes", (self.out / "run-summary.txt").read_text())

    def test_lockfile_only_change_is_filtered_unless_requested(self):
        (self.repo / "yarn.lock").write_text("lock\n")
        self.git("add", "yarn.lock")
        self.assertEqual(self.run_helper("--staged", "--dry-run").returncode, 3)
        result = self.run_helper("--staged", "--dry-run", "--include-generated")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("yarn.lock", (self.out / "staged.diff").read_text())

    def test_prompt_carries_rules_history_and_wide_context(self):
        (self.repo / "src" / "app.py").write_text("".join(f"line{i}\n" for i in range(30)))
        self.git("commit", "-qam", "expand app")
        (self.repo / "src" / "app.py").write_text("".join(
            f"line{i}\n" if i != 15 else "changed\n" for i in range(30)))
        result = self.run_helper("--working", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        prompt = (self.out / "prompt.md").read_text()
        self.assertIn("Root rule: never log secrets.", prompt)
        self.assertIn("Src rule: keep functions pure.", prompt)
        self.assertIn("expand app", prompt)
        self.assertIn(" line5\n", prompt)  # 10 context lines before the change
        self.assertIn("Confidence Rubric", prompt)
        self.assertIn("Not Findings", prompt)

    def test_large_untracked_file_is_listed_not_inlined(self):
        (self.repo / "src" / "app.py").write_text("x = 2\n")
        (self.repo / "dump.txt").write_text("y" * 200000)
        result = self.run_helper("--working", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("dump.txt", (self.out / "working.diff").read_text())
        self.assertIn("dump.txt (untracked, 200000 bytes)", (self.out / "prompt.md").read_text())

    def test_base_mode_diffs_against_merge_base(self):
        (self.repo / "src" / "app.py").write_text("x = 3\n")
        self.git("commit", "-qam", "change")
        result = self.run_helper("--base", "HEAD~1", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("range=HEAD~1...HEAD", (self.out / "run-summary.txt").read_text())
        self.assertIn("+x = 3", (self.out / "range.diff").read_text())

    def test_missing_path_is_rejected(self):
        result = self.run_helper("--path", "nope.py", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)

    def test_codex_is_read_only_with_model_and_events_on_both_cli_shapes(self):
        (self.repo / "src" / "app.py").write_text("x = 4\n")
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                (self.root / "codex-calls.jsonl").exists() and (self.root / "codex-calls.jsonl").unlink()
                result = self.run_helper("--working", legacy=legacy)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = self.codex_calls()[0]["args"]
                self.assertEqual(args[0], "exec")
                self.assertNotIn("--full-auto", args)
                self.assertEqual(args[args.index("-s") + 1], "read-only")
                self.assertEqual(args[args.index("-m") + 1], "trae/gpt-6.1-sol-max")
                self.assertIn('model_reasoning_effort="high"', args)
                self.assertIn("--json", args)
                self.assertIn("+x = 4", self.codex_calls()[0]["prompt"])
                self.assertIn("Codex assessment", (self.out / "assessment.md").read_text())
                self.assertIn('"type": "event"', (self.out / "codex-events.jsonl").read_text())
                self.assertIn("[run-cross-review] target_reviewer=codex",
                              (self.out / "assessor-run.log").read_text())


if __name__ == "__main__":
    unittest.main()
