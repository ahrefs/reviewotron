(** Select the local review input from a path and Git state. *)

type requested_mode =
  | Auto
  | Diff
  | Path

type path_selection = {
  path : string;
  project_root : string;
}

type diff_selection = {
  root : string;
  base : string;
  tracked_diff : string;
  untracked_files : string list;
}

type path_kind =
  | File
  | Directory

(** Classify a filesystem path, rejecting anything that is neither a regular
    file nor a directory (sockets, fifos, ...) and reporting a clear error when
    the path cannot be read (e.g. does not exist). *)
val path_kind : string -> (path_kind, string) result

type selection =
  | Review_path of path_selection
  | Review_diff of diff_selection

(** Select a path review or Git diff review. [root] is an optional worktree
    hint, and [base] is an optional explicit Git base ref. *)
val select :
  requested_mode:requested_mode -> path:string -> root:string option -> base:string option -> (selection, string) result

(** Injectable form used by unit tests and alternate Git runners. *)
val select_with :
  discover_root:(cwd:string -> (string, string) result) ->
  infer_base:(root:string -> explicit:string option -> (string, string) result) ->
  diff_against_base:(root:string -> base:string -> (string, string) result) ->
  untracked_files:(root:string -> (string list, string) result) ->
  requested_mode:requested_mode ->
  path:string ->
  root:string option ->
  base:string option ->
  (selection, string) result
