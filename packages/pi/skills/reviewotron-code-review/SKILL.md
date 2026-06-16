---
name: reviewotron-code-review
description: Run Reviewotron from Pi for independent code review. Use when the user asks for review, before final delivery of code changes, after substantial edits, or during review-fix-re-review loops.
---

# Reviewotron Code Review

Reviewotron is a local CLI review core. The Pi extension exposes it as the `reviewotron_review` tool and as slash commands.

## When To Use

Use Reviewotron when:

- The user asks for a review, audit, second pass, or preflight check.
- You have made meaningful implementation changes and want an independent review before final delivery.
- You fixed findings and need to confirm the updated diff is clean.
- The task touches security-sensitive behavior, auth, data access, parsing, shell execution, or external I/O.

Skip Reviewotron when:

- The user explicitly asks not to run checks.
- The change is documentation-only and the user did not ask for review.
- Required API credentials are unavailable and the user only asked for local mechanical edits.

## Tool Usage

For fast iteration on current changes:

```json
{
  "mode": "worktree_diff",
  "profile": "quick"
}
```

For a supplied unified diff:

```json
{
  "mode": "stdin_diff",
  "profile": "quick",
  "diff": "<unified diff>"
}
```

For a final or whole-project review:

```json
{
  "mode": "path",
  "profile": "full",
  "path": "."
}
```

Quick reviews disable the security pipeline for latency. Full reviews keep security enabled and raise Reviewotron size limits. The extension discovers supported config fields from `reviewotron config-help` before constructing full-review inline config.

## Review Loop

1. Run `reviewotron_review` with `profile=quick` after a meaningful code change.
2. Read each finding as a concrete defect report, not as a style suggestion by default.
3. Fix confirmed findings in the smallest relevant code area.
4. Re-run `reviewotron_review` on the updated diff.
5. Before final delivery, use `profile=full` for larger generated apps or security-sensitive work.

## Setup Errors

If the tool reports that the binary is missing, tell the user to install `reviewotron` on `PATH` or set `REVIEWOTRON_BIN` to the binary path.

If the tool reports missing LLM credentials, tell the user to set `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY`, or pass credentials through their normal Reviewotron setup.
