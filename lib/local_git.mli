(** Git helpers for local review defaults. *)

type run_git = cwd:string -> string list -> (string, string) result

(** Run [git -C cwd ...] and return trimmed stdout. *)
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

(** Infer a base ref using [explicit] when supplied, otherwise common remote
    default-branch refs. *)
val infer_base_with : run_git:run_git -> root:string -> explicit:string option -> (string, string) result

val infer_base : root:string -> explicit:string option -> (string, string) result

(** Generate [git diff $(git merge-base HEAD base)], including working-tree
    changes. *)
val diff_against_base_with : run_git:run_git -> root:string -> base:string -> (string, string) result

val diff_against_base : root:string -> base:string -> (string, string) result
