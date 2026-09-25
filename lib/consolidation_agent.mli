(** Verifies whether two independently confirmed findings can be presented as
    one finding without losing evidence. *)

type verdict =
  | Keep_separate
  | Consolidate

type affected_location = {
  path : string;
  line : int;
  evidence : string;
}

type output = {
  verdict : verdict;
  reason : string;
  shared_cause : string;
  shared_repair : string;
  primary_path : string;
  primary_line : int;
  affected_locations : affected_location list;
  member_finding_ids : int list;
  assumptions : string list;
}

type consolidation = {
  shared_cause : string;
  shared_repair : string;
  primary_path : string;
  primary_line : int;
  affected_locations : affected_location list;
  member_finding_ids : int list;
}

val output_of_json : Yojson.Basic.t -> output
val output_to_json : output -> Yojson.Basic.t
val config : Agent_runner.agent_config

val build_input :
  diff_text:string ->
  left_id:int ->
  left:Security_types.validated_finding ->
  right_id:int ->
  right:Security_types.validated_finding ->
  string

val tools : fetch_file:(string -> (string option, string) result Lwt.t) -> (string * Ai_core.Core_tool.t) list

(** Accept a consolidation only when the model returned both member IDs, both
    affected sink locations, a concrete cause and repair, and no assumptions. *)
val verify :
  left_id:int ->
  left:Security_types.validated_finding ->
  right_id:int ->
  right:Security_types.validated_finding ->
  output ->
  (consolidation, string) result
