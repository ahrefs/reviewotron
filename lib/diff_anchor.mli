(** Pure helpers for anchoring findings onto positions in a parsed diff.

    Extracted from {!Reviewer} so both the generic reviewer and the security
    plugin can share them without a cyclic dependency. *)

(** Per-hunk [(new_start, new_end)] ranges on the new-file side of the diff. *)
val right_line_ranges : Diff_parser.file_diff -> (int * int) list

(** Nearest in-diff line on the new-file side, preferring exact containment.
    Returns [None] only if the file has no right-side hunks at all. *)
val nearest_right_line_in_diff : Diff_parser.file_diff -> target_line:int -> int option

(** Whether [line] sits inside any right-side hunk. *)
val line_in_right_range : Diff_parser.file_diff -> line:int -> bool

(** Resolve a finding to a line that appears in the diff on the new-file side.
    Returns the original line if it's in range, otherwise snaps to the nearest
    in-range line, otherwise [None] (no right-side hunks at all). *)
val resolve_right_line : Diff_parser.file_diff -> target_line:int -> int option

(** Whether the closed range [start_line..end_line] sits inside a single
    right-side hunk.  GitHub rejects multi-line review comments whose range
    straddles a hunk boundary, so this gates multi-line emission. *)
val single_hunk_contains : Diff_parser.file_diff -> start_line:int -> end_line:int -> bool

(** Locate the [file_diff] whose path matches [path], tolerating path prefixes
    like [a/]/[b/] that agents sometimes copy from unified diffs.  Falls back
    to an unambiguous basename match before giving up. *)
val find_file_diff_by_path : diff:Diff_parser.file_diff list -> string -> Diff_parser.file_diff option
