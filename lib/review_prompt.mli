(** Prompt construction for Claude code review.
    Builds system prompts and user messages from diffs, PR metadata, and file contents. *)

(** JSON Schema for the [submit_review] tool's [input_schema], matching {!Review_types.review_output}. *)
val review_schema : Yojson.Safe.t

(** System prompt instructing Claude how to review code.
    Uses [override] if provided, otherwise the default prompt. *)
val system_prompt : ?override:string -> unit -> string

(** Build the user message containing the diff and context.
    [file_contents] is a list of [(path, content)] pairs for additional context. *)
val build_user_message :
  diff:string -> ?pr_title:string -> ?pr_description:string -> ?file_contents:(string * string) list -> unit -> string

(** Rough token estimate for the prompt (~4 chars per token). *)
val estimate_prompt_tokens : system:string -> user:string -> int
