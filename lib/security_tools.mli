(** Tools for security analysis agents.

    Provides typed wrappers around {!Ai_core.Core_tool.t} for use
    with {!Agent_runner.run_agent}. Tool parameters and results are
    derived from OCaml types — no manual JSON. *)

(** {2 get_file_content tool} *)

(** Parameters for the [get_file_content] tool. *)
type get_file_content_params = { path : string } [@@deriving json]

val get_file_content_params_jsonschema : Yojson.Basic.t

(** Result returned by the [get_file_content] tool. *)
type get_file_content_result = {
  content : string option; [@json.option]
  error : string option; [@json.option]
}
[@@deriving json]

val get_file_content_result_jsonschema : Yojson.Basic.t

(** Create a [get_file_content] tool for security agents.

    Returns [(name, tool)] suitable for passing to
    {!Agent_runner.run_agent}'s [~tools] parameter.

    @param fetch_file Callback that fetches file content given a path.
      Returns [Ok (Some content)] on success, [Ok None] if not found,
      or [Error msg] on failure. The caller captures repo URL, commit
      ref, and API credentials in the closure. *)
val make_get_file_content : fetch_file:(string -> (string option, string) result Lwt.t) -> string * Ai_core.Core_tool.t
