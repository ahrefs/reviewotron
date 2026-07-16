(** Git helpers for local review defaults. *)

type run_git = cwd:string -> string list -> (string, string) result

(** Run [git -C cwd ...] and return trimmed stdout, or [Error _] when the
    process cannot be started or exits unsuccessfully. *)
val run_git : run_git

(** Return an absolute, real path where possible. *)
val normalize_path : string -> string

(** Discover the Git worktree root from [cwd]. *)
val discover_root : cwd:string -> (string, string) result

(** Return the Git worktree root, or [cwd] when [cwd] is not in a worktree. *)
val default_root : cwd:string -> string

(** Stable default repo key for local review state and memory paths. *)
val default_repo_key : root:string -> string

(** Default title for generated diffs. *)
val title_for_base : string -> string

(** Default title for explicit diff files. *)
val title_for_diff_file : string -> string

(** Default title for a selected commit. *)
val title_for_commit : string -> string

(** Infer a base ref using [explicit] when supplied, otherwise common remote
    default-branch refs. *)
val infer_base_with : run_git:run_git -> root:string -> explicit:string option -> (string, string) result

val infer_base : root:string -> explicit:string option -> (string, string) result

(** Generate [git diff $(git merge-base HEAD base)], including working-tree
    changes. *)
val diff_against_base_with : run_git:run_git -> root:string -> base:string -> (string, string) result

val diff_against_base : root:string -> base:string -> (string, string) result

(** Run Git and preserve stdout exactly, including trailing newlines and bytes. *)
val run_git_raw : run_git

(** Resolve a commit-ish to its full commit SHA. *)
val resolve_commit_with : run_git:run_git -> root:string -> revision:string -> (string, string) result

val resolve_commit : root:string -> revision:string -> (string, string) result

(** The type of a Git object at [revision:path]. [Missing] means the path is not
    present in the revision (rather than a transient/corrupt-object failure,
    which cannot be distinguished here as Git's stderr is suppressed). [Object]
    carries the type name Git reports ("blob", "tree", ...). *)
type object_type =
  | Object of string
  | Missing

val object_type_with : run_git:run_git -> root:string -> revision:string -> path:string -> object_type

val object_type : root:string -> revision:string -> path:string -> object_type

(** Generate the selected commit's first-parent diff. [path] adds a Git
    pathspec; when omitted the whole commit is compared. Root commits are
    compared against Git's empty tree. *)
val diff_against_commit_with :
  run_git:run_git -> root:string -> commit:string -> ?path:string -> unit -> (string, string) result

val diff_against_commit : root:string -> commit:string -> ?path:string -> unit -> (string, string) result

(** Return non-ignored untracked paths relative to the worktree root. *)
val untracked_files_with : run_git:run_git -> root:string -> (string list, string) result

val untracked_files : root:string -> (string list, string) result
