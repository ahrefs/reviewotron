# @reviewotron/pi

Pi package for running Reviewotron from the existing local CLI binary.

## Install Locally

```bash
pi install ./packages/pi
```

For a temporary run:

```bash
pi -e ./packages/pi
```

## Requirements

- `reviewotron` must be on `PATH`, or `REVIEWOTRON_BIN` must point to the binary.
- Set `OPENROUTER_API_KEY` or `ANTHROPIC_API_KEY` for local reviews.

The package runs the local `reviewotron` process. Reviewed code stays local except for the model provider calls made by Reviewotron itself.

Pi packages and extensions execute with the permissions of the Pi process. Review this package before installing it in a sensitive workspace.

## Commands

- `/reviewotron` reviews the current git diff with quick settings and `--no-security`.
- `/reviewotron-full [path]` reviews a path, or `.` when omitted, with raised size limits and security enabled.
- `/reviewotron-config` runs `reviewotron config-help` and summarizes available config fields.

For full reviews, the adapter first runs `reviewotron config-help` and uses the returned JSON Schema to decide which inline config fields to pass. The schema is cached per binary path/version for the Pi session. If schema discovery fails but the binary exists, the adapter falls back to conservative built-in full-review defaults.

## Tool

The extension registers `reviewotron_review`.

```json
{
  "mode": "worktree_diff",
  "profile": "quick"
}
```

Supported modes:

- `worktree_diff`: review the current git diff.
- `stdin_diff`: review a unified diff supplied in `diff`.
- `path`: review a file or directory.

By default, `quick` passes `--no-security`; `full` leaves security enabled and passes supported raised limit fields such as `{"max_files":500,"max_diff_lines":50000}` as inline config.
