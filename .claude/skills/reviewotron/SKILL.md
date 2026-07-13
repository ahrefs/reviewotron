---
name: reviewotron
description: Review current repository changes or a requested path with Reviewotron.
---

# Reviewotron

Use this skill when the user asks for a code review or asks to review the current changes.

1. Use the repository path from the agent context. Run Reviewotron from that repository so its automatic Git detection sees the right worktree.
2. Prefer an installed `reviewotron` found with `command -v reviewotron`.
3. When the current repository is the Reviewotron checkout and no installed binary is available, use `dune exec -- src/reviewotron.exe`.
4. If neither is available, stop with a clear setup error and tell the user to run `make install`; do not download or install a binary automatically.
5. Run the binary with JSON output:

   ```bash
   reviewotron . --output json
   ```

   Pass a specific path supplied by the user in place of `.`. Add `--mode path` only when the user explicitly asks for a whole-file or whole-tree review. Leave automatic Git/diff selection to the binary.

6. Parse the single JSON response. Summarize `findings` and the `summary`; surface a non-zero exit or an `{ "error": ... }` response as a failed review.

Do not manage Reviewotron configuration or reproduce its precedence rules. The binary owns Git detection, untracked-file discovery, config loading, filtering, and output behavior.
