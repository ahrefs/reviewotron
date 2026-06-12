(** Ingest a local file or directory as a synthesized "all additions" unified
    diff.

    This lets the review engine review code that has no Git history at all —
    a single file, a freshly generated project folder, or any non-Git working
    tree. Every ingested file is rendered as a newly-added file, so the result
    is a normal unified diff that flows through the same filtering, size limits,
    diff annotation, anchoring, and plugins as a real diff. *)

(** A prepared review input synthesized from a local path. *)
type t = {
  root : string;
    (** Normalized directory used both for diff paths and for context-file
          lookups during review. For a file target this is its parent
          directory; for a directory target it is the directory itself. *)
  diff_text : string;  (** Synthesized unified diff: every file marked added. *)
  title : string;  (** Default review title describing the target. *)
  file_count : int;  (** Number of files included in the synthesized diff. *)
}

(** Directory names skipped during a recursive walk: build outputs and
    dependency caches that should never be reviewed. Hidden entries (names
    starting with ["."]), which already cover [.git] and friends, are skipped
    separately and are not listed here. *)
val default_skip_dirs : string list

(** [ingest path] reads [path] and synthesizes a review input.

    - When [path] is a regular file, [root] is its parent directory and the
      diff contains that one file.
    - When [path] is a directory, [root] is the directory itself and the diff
      contains every regular file under it, recursively, in sorted (stable)
      order so the synthesized diff is deterministic across runs.

    While walking a directory the following are skipped: hidden entries,
    symlinks, the directories in {!default_skip_dirs}, and files that are not
    embeddable (binary, non-UTF-8, or larger than the prompt byte cap — see
    {!Review_job.is_embeddable}). Per-entry read or stat failures are logged and
    skipped rather than aborting the walk.

    Returns [Error _] when [path] does not exist, is neither a file nor a
    directory, or yields no embeddable files. *)
val ingest : string -> (t, string) result
