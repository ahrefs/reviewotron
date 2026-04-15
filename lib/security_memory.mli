(** Repo security memory: per-repo markdown files storing security context
    for injection into agent prompts. See PRD §6. *)

(** Derive a filesystem-safe slug from a repo URL.
    Strips protocol/host, [.git] suffix, and trailing slashes, then replaces [/] with [-].
    e.g. "https://github.com/ahrefs/monorepo" -> "ahrefs-monorepo" *)
val repo_slug : string -> string

(** Full filesystem path to the memory file for a given repo. *)
val memory_path : memory_dir:string -> repo_url:string -> string

(** Load the memory file contents. Returns [None] if file doesn't exist or is empty. *)
val load : memory_dir:string -> repo_url:string -> string option

(** Save memory content to the file, creating the directory if needed.
    Uses atomic writes via [Files.save_as]. *)
val save : memory_dir:string -> repo_url:string -> content:string -> unit
