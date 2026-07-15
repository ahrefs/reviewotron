(** Conservative generated-file classifier for parsed diffs.

    Generated files are excluded from review input before diff size limits are
    enforced. The classifier intentionally avoids broad directory names such as
    [generated], [dist], [build], or [vendor], because those can contain changes
    humans expect to review. *)

type skipped_file = {
  path : string;
  reason : string;
}

(** Return [Some skipped] when the file diff should be treated as generated. *)
val classify : Diff_parser.file_diff -> skipped_file option

(** Remove files matching [ignored_file_regexes] and, when enabled, the
    built-in generated-file rules. Regexes are matched against each file's
    current repository-relative path. Preserves input order for reviewed files
    and skipped-file metadata. *)
val filter :
  ?ignored_file_regexes:string list ->
  ?ignore_generated_files:bool ->
  Diff_parser.t ->
  Diff_parser.t * skipped_file list

(** Render skipped files as a ["path (reason), ..."] summary for logging.
    Returns [None] when nothing was skipped, so callers can skip the log line. *)
val describe_skipped : skipped_file list -> string option
