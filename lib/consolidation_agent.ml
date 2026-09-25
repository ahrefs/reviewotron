open Melange_json.Primitives
open Ppx_deriving_jsonschema_runtime.Primitives.Melange_json

type verdict =
  | Keep_separate
  | Consolidate

let verdict_to_json = function
  | Keep_separate -> `String "keep_separate"
  | Consolidate -> `String "consolidate"

let verdict_of_json = function
  | `String "keep_separate" -> Keep_separate
  | `String "consolidate" -> Consolidate
  | json -> Melange_json.of_json_error ~json "expected consolidation verdict string"

let verdict_jsonschema =
  `Assoc
    [
      "type", `String "string";
      "enum", `List [ `String "keep_separate"; `String "consolidate" ];
      "description", `String "Whether the two findings can be losslessly consolidated.";
    ]

type affected_location = {
  path : string;
  line : int;
  evidence : string;
}
[@@deriving json, jsonschema]

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
[@@deriving json, jsonschema]

type consolidation = {
  shared_cause : string;
  shared_repair : string;
  primary_path : string;
  primary_line : int;
  affected_locations : affected_location list;
  member_finding_ids : int list;
}

let system_prompt =
  {|You verify whether two independently confirmed security findings can be presented as one finding without losing evidence.

Consolidate only when both findings arise from the same specific causal defect or missing control and one concrete repair at that shared cause resolves both findings. Similar vulnerability classes, repeated patterns, nearby lines, the same principal, or fixes that merely belong in one patch are insufficient.

Every consolidation must:
- identify the shared cause and one concrete shared repair;
- preserve both member IDs and both dangerous sink locations in affected_locations;
- choose a real primary anchor for the shared cause;
- retain enough location-specific evidence to understand each impact;
- have no unresolved assumptions.

Use get_file_content when repository evidence is needed to prove a shared source of truth, generated relationship, or shared control. The supplied diff is primary evidence for changed lines, so do not refetch files already shown there. When an affected file is marked generated or managed, derive a likely generator path from its artifact name and the source finding's repository area; common layouts put `gen_<artifact>` under a nearby `gen_files` directory. Make at most two targeted file lookups. If those do not prove the relationship, keep the findings separate.

Return keep_separate when the relationship is uncertain, either repair can be applied independently, the shared cause is only thematic, repository evidence is missing, or any assumption remains. Empty consolidation-only fields when keeping findings separate. Never invent IDs or locations.

Your response must be one JSON object matching the schema, with no markdown or surrounding prose.|}

let config : Agent_runner.agent_config =
  {
    name = "security_consolidation_verifier";
    system_prompt;
    model_tier = Standard;
    output_schema = output_jsonschema;
    max_steps = 4;
    thinking_budget = None;
    effort = None;
  }

let build_input ~diff_text ~left_id ~left ~right_id ~right =
  Printf.sprintf {|## Findings

Finding ID %d:
%s

Finding ID %d:
%s

## Annotated diff

%s|} left_id
    (Security_types.validated_finding_to_json left |> Yojson.Basic.pretty_to_string)
    right_id
    (Security_types.validated_finding_to_json right |> Yojson.Basic.pretty_to_string)
    diff_text

let tools ~fetch_file = [ Security_tools.make_get_file_content ~fetch_file ]

let nonempty value = not (String.equal (String.trim value) "")

let contains_location locations (sink : Security_types.sink_evidence) =
  List.exists (fun location -> String.equal location.path sink.path && Int.equal location.line sink.line) locations

let verify ~left_id ~(left : Security_types.validated_finding) ~right_id ~(right : Security_types.validated_finding)
  (output : output) =
  let expected_ids = List.sort_uniq Int.compare [ left_id; right_id ] in
  let actual_ids = List.sort_uniq Int.compare output.member_finding_ids in
  match output.verdict with
  | Keep_separate -> Error output.reason
  | Consolidate ->
  match () with
  | () when not (List.equal Int.equal expected_ids actual_ids) -> Error "member IDs do not match the proposed pair"
  | () when List.compare_length_with output.assumptions 0 > 0 -> Error "consolidation has unresolved assumptions"
  | () when not (nonempty output.shared_cause) -> Error "consolidation has no shared cause"
  | () when not (nonempty output.shared_repair) -> Error "consolidation has no shared repair"
  | () when (not (nonempty output.primary_path)) || output.primary_line <= 0 ->
    Error "consolidation has no valid primary anchor"
  | () when not (contains_location output.affected_locations left.finding.sink) ->
    Error "consolidation omits the left finding's sink"
  | () when not (contains_location output.affected_locations right.finding.sink) ->
    Error "consolidation omits the right finding's sink"
  | () ->
    Ok
      {
        shared_cause = output.shared_cause;
        shared_repair = output.shared_repair;
        primary_path = output.primary_path;
        primary_line = output.primary_line;
        affected_locations = output.affected_locations;
        member_finding_ids = actual_ids;
      }
