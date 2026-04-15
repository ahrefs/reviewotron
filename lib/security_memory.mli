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

(** {2 Memory update queue}

    Append-only JSONL queue for distributed safety (PRD §6.4).
    Multiple reviewotron instances can append concurrently; the curator
    processes the queue serially. *)

(** Full filesystem path to the queue file for a given repo. *)
val queue_path : memory_dir:string -> repo_url:string -> string

(** Append a memory update entry to the queue file.
    Creates the directory and file if needed.  Each entry is a single
    JSON line (JSONL format) for concurrent-append safety. *)
val append_update : memory_dir:string -> repo_url:string -> update:Security_types.memory_update -> unit

(** Read all pending update entries from the queue.
    Returns an empty list if the file doesn't exist or is empty.
    Skips malformed lines with a warning. *)
val read_updates : memory_dir:string -> repo_url:string -> Security_types.memory_update list

(** Truncate the queue file to zero length.
    Called after the curator has successfully processed all entries. *)
val truncate_queue : memory_dir:string -> repo_url:string -> unit
