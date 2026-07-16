---
name: reviewotron
description: Review current repository changes or a requested path with Reviewotron.
---

# Reviewotron

Use this skill when the user asks for a code review, or asks to review the
current changes, a path, or a specific commit.

Reviewotron ships a single CLI (`reviewotron`). Its **default command** is a
smart local review: run `reviewotron` with no subcommand and it detects the Git
worktree, picks diff-vs-path mode automatically, and reviews. You almost always
want the default command — reach for `review-diff` / `review-path` only when the
user hands you a raw diff or an explicit whole-file review.

## 1. Locate or install the binary

**First, check whether the binary is already installed.** Do this before
anything else — do not install if a working binary exists.

```bash
command -v reviewotron || ls ~/.local/bin/reviewotron
```

`~/.local/bin` may not be on `PATH`, so check that explicit path too. If either
resolves, use it (invoke by full path if it is not on `PATH`) and skip the rest
of this section.

**If it is not installed, check whether the install preconditions are met**
before attempting an install. Installation only works from the Reviewotron
source tree, so confirm all of:

- The current repository (or a directory the user points you to) *is* the
  Reviewotron checkout — a `dune-project` naming `reviewotron` and
  `src/reviewotron.ml` are present.
- Its local opam switch resolves: `eval $(opam env)` from the repo root
  succeeds. This project uses its **own local switch**; do not `opam install`
  anything to make it resolve.

When the preconditions hold, you have two ways to run:

- **Run from the checkout without installing** (good for a one-off review inside
  the source tree):

  ```bash
  eval $(opam env) && dune exec -- src/reviewotron.exe [ARGS]
  ```

- **Install to `~/.local/bin`** (do this when the user wants a reusable
  `reviewotron` on their `PATH`; tell the user before you install):

  ```bash
  cd <reviewotron-checkout> && eval $(opam env) && make install
  ```

  This builds a release binary and copies it to `$(PREFIX)/bin`, with `PREFIX`
  defaulting to `~/.local` (override with `make install PREFIX=/custom/prefix`).
  If `command -v reviewotron` still fails afterward, `~/.local/bin` is not on
  `PATH` — tell the user to add `export PATH="$HOME/.local/bin:$PATH"` to their
  shell profile; meanwhile invoke `~/.local/bin/reviewotron` by full path.

**If you cannot find an installed binary and the install preconditions are not
met** (no Reviewotron checkout reachable, or the switch does not resolve), stop
and ask the user where the Reviewotron checkout is or how they want it
installed. Never download a prebuilt binary from the network, and never
`opam install` to force the switch.

## 2. Confirm an API key is available

A real review calls an LLM, so the binary needs a key. **Check that a key is
available before you run the CLI** — do not discover it is missing by running a
review and reading the error. The binary resolves a key from, in order: the
`--openrouter-api-key` / `--anthropic-api-key` flag → the `OPENROUTER_API_KEY` /
`ANTHROPIC_API_KEY` environment variable → a `--secrets` file (only if you pass
one). No secrets file is required.

Check the expected sources up front, without invoking `reviewotron`:

```bash
# Present if either prints a value:
printf '%s' "${OPENROUTER_API_KEY:+set}${ANTHROPIC_API_KEY:+set}"
```

- **If one of the env vars is set**, the key is available — just run, and do not
  pass a `--openrouter-api-key` / `--anthropic-api-key` flag (the env var is
  picked up automatically).
- **If a `--secrets` file is the intended source** and the user pointed you at
  one, pass `--secrets <path>`; you do not need an env var.
- **If no key is available in any expected way**, stop. Ask the user how they
  want to provision it — which provider (OpenRouter or Anthropic), and whether
  via an environment variable or a `--secrets` file. Do not invent, guess, or
  hardcode a key.

  After they answer, **record the arrangement as a memory** so future sessions
  do not re-ask: write a `reference`-type memory capturing which provider/env
  var the user uses for Reviewotron (the *mechanism* — e.g. "uses
  `OPENROUTER_API_KEY` from their shell profile" — **never the key value
  itself**), and add its pointer line to `MEMORY.md`.

The one case that needs **no** real key is an intentional **offline dry run**
(see the offline check at the end), used only to verify the binary runs.

## 3. Run the review

Run from the repository the user wants reviewed, so Git detection sees the right
worktree. Use JSON output so you can parse the result:

```bash
reviewotron [PATH] --output json
```

Because the smart review is the default command, flags and the optional `PATH`
go directly after `reviewotron` (no subcommand). Map the user's intent to flags:

| User intent | Command |
|-------------|---------|
| Review current changes (default) | `reviewotron --output json` |
| Review a specific path's changes | `reviewotron path/to/dir --output json` |
| Review a whole file/tree as new code | `reviewotron path --mode path --output json` |
| Review one commit (whole commit) | `reviewotron --commit <ref> --output json` |
| Review one commit, scoped to a path | `reviewotron --commit <ref> path/ --output json` |
| Diff against a specific base ref | `reviewotron --base <ref> --output json` |
| Turn off the security pipeline | add `--no-security` |

Notes that change behavior:

- **PATH default is the current directory.** Pass the user's path in its place
  when they name one.
- **`--mode`** (`auto` default): `auto` picks Git-delta review for a directory
  in a worktree and path review for a single file or a non-Git path; `diff`
  forces Git delta (and errors if none); `path` reviews the target as newly
  added code. Only pass `--mode path` when the user explicitly wants a
  whole-file/whole-tree review rather than a diff.
- **`--commit <ref>`** reviews only that commit against its first parent and
  ignores the worktree. With no PATH it reviews the whole commit; an explicit
  PATH scopes it. `--commit` cannot be combined with `--diff`, `--base`, or
  `--mode path`.
- **`--base <ref>`** sets the base for the generated Git diff; without it the
  binary tries `origin/HEAD`, `origin/main`, `origin/master`, then the upstream.
- **Security runs by default** in local mode; use `--no-security` to skip it
  (faster, general-review-only).

Let the binary own Git detection, untracked-file discovery, config loading
(`.reviewotron.json`), filtering, and precedence. Do not reproduce or manage its
configuration.

## 4. Interpret the result

The command emits **one** JSON object and an exit code:

- Exit `0` with `{ "summary": ..., "findings": [ ... ] }` → a completed review.
  Report the `summary` and each finding to the user. An empty `findings` array
  is a clean review, not a failure.
- `{ "error": "..." }` (and/or a non-zero exit) → a failed review. Surface the
  error verbatim. Common, non-bug errors: `no changes to review` (the worktree
  or commit had nothing in scope) and a base-inference failure (suggest `--base`
  or `--mode path`).

## Verifying the setup without a key (optional)

To confirm the binary runs end-to-end with no network and no real key — e.g.
right after installing — do an offline dry run that disables both plugins:

```bash
reviewotron --commit HEAD \
  --config '{"review_plugins":{"general":{"enabled":false}}}' \
  --no-security --anthropic-api-key dummy --output json
```

Exit `0` with a JSON body proves ingestion → diff prep → engine → rendering all
work. Note: inline `--config` cannot re-enable security once `--no-security` is
passed (the flag wins); this run is a plumbing check only, not a real review.
