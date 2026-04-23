(** Prompt construction for Claude code review.
    Builds system prompts and user messages from diffs, PR metadata, and file contents. *)

(** JSON Schema for the [submit_review] tool's [input_schema], matching {!Review_types.review_output}. *)
val review_schema : Yojson.Safe.t

(** System prompt instructing Claude how to review code.

    If [override] is provided, it is returned verbatim (the caller takes
    full control).  Otherwise the prompt is assembled from static parts
    plus a security clause selected by [security_covered_elsewhere]:

    - [true]: the general review is told NOT to emit security findings
      because a specialized security review pipeline is running.
    - [false]: the general review is told to include security in scope. *)
val system_prompt : ?override:string -> security_covered_elsewhere:bool -> unit -> string

(** Build the user message containing the diff and context.
    [file_contents] is a list of [(path, content)] pairs for additional context. *)
val build_user_message :
  diff:string -> ?pr_title:string -> ?pr_description:string -> ?file_contents:(string * string) list -> unit -> string

(** Rough token estimate for the prompt (~4 chars per token). *)
val estimate_prompt_tokens : system:string -> user:string -> int
