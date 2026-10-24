#!/usr/bin/env python3
"""Capture review events and resume a timed-out Claude session once to wrap up."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import uuid


REVIEW_MODEL = "claude-opus-5-5"
REVIEW_EFFORT = "high"
# Read-only file access only: no Bash, since git/find/sed can all write.
READ_ONLY_TOOLS = "Read,Grep,Glob"


WRAP_UP = """The review time budget has expired. Continue this same session and
produce the final assessment now, using only evidence you already inspected.
Do not restart the review, run tools/tests, or request more files. Report confirmed
findings with locations, distinguish unresolved questions and unverified claims,
and explicitly state incomplete coverage. If there is insufficient evidence for
an accept/block verdict, say so. Do not treat an interrupted review as a pass.
"""


def stop_group(process):
    """Stop the reviewer and its tool children before any same-session resume."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # The leader may have exited while a tool child remains alive.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_attempt(command, repo, prompt, events, log, seconds):
    with prompt.open("rb") as source, events.open("wb") as output, log.open("ab") as errors:
        process = subprocess.Popen(
            command, cwd=repo, stdin=source, stdout=output, stderr=errors,
            start_new_session=True,
        )
        try:
            return process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            stop_group(process)
            return 124
        except BaseException:
            stop_group(process)
            raise


def final_result(events, session_id):
    """Only a successful terminal result counts, never partial assistant text."""
    result = None
    with events.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue  # Timeout can interrupt a JSON line.
            if isinstance(event, dict) and event.get("type") == "result":
                result = event
    if not result or result.get("session_id") != session_id:
        return None
    if result.get("subtype") != "success" or result.get("is_error") is not False:
        return None
    text = result.get("result")
    return text.strip() if isinstance(text, str) and text.strip() else None


def review(args):
    output = args.output_dir.resolve()
    session_id = str(uuid.uuid4())
    (output / "claude-session-id.txt").write_text(session_id + "\n")
    assessment = output / "assessment.md"
    assessment.write_text("")
    log = output / "assessor-run.log"

    def record(**fields):
        with (output / "run-summary.txt").open("a") as summary:
            for key, value in fields.items():
                summary.write(f"{key}={value}\n")

    common = [
        "claude", "-p", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--model", REVIEW_MODEL,
        "--effort", REVIEW_EFFORT, "--disable-slash-commands",
    ]
    # --tools limits what exists; --allowedTools only skips prompts, so it is
    # never a sandbox on its own. dontAsk denies anything not pre-approved.
    command = common + [
        "--session-id", session_id, "--strict-mcp-config", "--permission-mode", "dontAsk",
    ]
    if args.self_contained:
        command += ["--tools", ""]
    else:
        command += [
            "--tools", READ_ONLY_TOOLS, "--allowedTools", READ_ONLY_TOOLS,
            "--add-dir", str(args.repo), "--add-dir", str(output),
        ]
    events = output / "claude-events.jsonl"
    record(claude_session_id=session_id, claude_model=REVIEW_MODEL,
           claude_effort=REVIEW_EFFORT, claude_events=events)
    rc = run_attempt(command, args.repo, args.prompt, events, log, args.timeout_seconds)
    record(initial_exit=rc, resume_attempted=int(rc == 124))
    if rc == 124:
        # Never use --continue (another concurrent review may be the latest).
        prompt = output / "resume-prompt.md"
        prompt.write_text(WRAP_UP)
        events = output / "claude-resume-events.jsonl"
        command = common + [
            "--resume", session_id, "--tools", "", "--strict-mcp-config",
            "--permission-mode", "dontAsk",
        ]
        record(claude_resume_events=events)
        with log.open("a") as errors:
            errors.write(f"\nReview timed out; wrapping up session {session_id} with the same model.\n")
        rc = run_attempt(command, args.repo, prompt, events, log, args.resume_timeout_seconds)
        record(resume_exit=rc)
    if rc != 0:
        return rc if rc > 0 else 1
    result = final_result(events, session_id)
    if result is None:
        with log.open("a") as errors:
            errors.write("No successful nonempty terminal result for this session; review is incomplete.\n")
        return 1
    assessment.write_text(result + "\n")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--prompt", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--resume-timeout-seconds", type=int, default=300)
    parser.add_argument("--self-contained", action="store_true")
    args = parser.parse_args()
    if args.timeout_seconds <= 0 or args.resume_timeout_seconds <= 0:
        parser.error("Timeouts must be positive.")
    return review(args)


if __name__ == "__main__":
    raise SystemExit(main())
