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

A new input allowlist is a shared repair only when repository evidence already establishes that restricted input domain. Do not invent a narrower input policy to combine context-specific quoting or escaping defects at different sinks; keep those findings separate unless one existing upstream contract demonstrably makes both sink-specific repairs unnecessary.

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

let build_input ?(relationship_evidence = "") ~diff_text ~left_id ~left ~right_id ~right () =
  let relationship_evidence =
    match String.trim relationship_evidence with
    | "" -> ""
    | evidence -> Printf.sprintf "\n\n## Located repository relationship evidence\n\n%s" evidence
  in
  Printf.sprintf {|## Findings

Finding ID %d:
%s

Finding ID %d:
%s

## Annotated diff

%s%s|} left_id
    (Security_types.validated_finding_to_json left |> Yojson.Basic.pretty_to_string)
    right_id
    (Security_types.validated_finding_to_json right |> Yojson.Basic.pretty_to_string)
    diff_text relationship_evidence

let strip_suffix ~suffix value =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  match value_length >= suffix_length with
  | false -> None
  | true ->
    let offset = value_length - suffix_length in
    (match String.equal (String.sub value offset suffix_length) suffix with
    | true -> Some (String.sub value 0 offset)
    | false -> None)

let stem_and_extension path =
  let basename = Filename.basename path in
  let extension = Filename.extension basename in
  let stem_length = String.length basename - String.length extension in
  String.sub basename 0 stem_length, extension

let ancestor_directories path =
  let rec collect remaining acc directory =
    match remaining, directory with
    | 0, _ | _, "." | _, "/" -> List.rev acc
    | _, _ -> collect (remaining - 1) (directory :: acc) (Filename.dirname directory)
  in
  collect 3 [] (Filename.dirname path)

let relationship_evidence_candidate_paths ~changed_paths ~affected_paths =
  let affected_names =
    affected_paths
    |> List.map (fun path -> Filename.dirname path |> Filename.basename)
    |> List.filter (fun name -> not (String.equal name "." || String.equal name ""))
    |> List.sort_uniq String.compare
  in
  let policy_paths =
    changed_paths
    |> List.concat_map (fun path ->
      let stem, extension = stem_and_extension path in
      match strip_suffix ~suffix:"_props" stem with
      | None -> []
      | Some prefix ->
        let directory = Filename.dirname path in
        [
          Filename.concat directory (prefix ^ "_access_policy" ^ extension);
          Filename.concat directory (prefix ^ "_policy" ^ extension);
        ])
  in
  let generator_paths =
    changed_paths
    |> List.concat_map (fun path ->
      let _, extension = stem_and_extension path in
      match String.equal extension "" with
      | true -> []
      | false ->
        ancestor_directories path
        |> List.concat_map (fun directory ->
          List.map
            (fun affected_name ->
              Filename.concat directory (Filename.concat "gen_files" ("gen_" ^ affected_name ^ extension)))
            affected_names))
  in
  List.sort_uniq String.compare policy_paths @ List.sort_uniq String.compare generator_paths

let relationship_evidence_content_limit = 12_000

let clip_relationship_evidence content =
  match String.length content <= relationship_evidence_content_limit with
  | true -> content
  | false -> String.sub content 0 relationship_evidence_content_limit ^ "\n[truncated]"

let fetch_relationship_evidence ~fetch_file paths =
  let rec fetch found_count blocks found_paths = function
    | [] -> Lwt.return (String.concat "\n\n" (List.rev blocks), List.rev found_paths)
    | _ when found_count >= 1 -> Lwt.return (String.concat "\n\n" (List.rev blocks), List.rev found_paths)
    | path :: rest ->
      let%lwt result = fetch_file path in
      (match result with
      | Ok (Some content) ->
        let block = Printf.sprintf "# File: %s\n%s" path (clip_relationship_evidence content) in
        fetch (found_count + 1) (block :: blocks) (path :: found_paths) rest
      | Ok None | Error _ -> fetch found_count blocks found_paths rest)
  in
  fetch 0 [] [] paths

let tools ~fetch_file = [ Security_tools.make_get_file_content ~fetch_file ]

let nonempty value = not (String.equal (String.trim value) "")

let contains_location locations (sink : Security_types.sink_evidence) =
  List.exists (fun location -> String.equal location.path sink.path && Int.equal location.line sink.line) locations

let preserve_sink locations (sink : Security_types.sink_evidence) =
  match contains_location locations sink with
  | true -> locations
  | false -> { path = sink.path; line = sink.line; evidence = sink.description } :: locations

let verify ~left_id ~(left : Security_types.validated_finding) ~right_id ~(right : Security_types.validated_finding)
  (output : output) =
  let expected_ids = List.sort_uniq Int.compare [ left_id; right_id ] in
  let actual_ids = List.sort_uniq Int.compare output.member_finding_ids in
  match output.verdict with
  | Keep_separate -> Error output.reason
  | Consolidate ->
    let affected_locations =
      preserve_sink (preserve_sink output.affected_locations left.finding.sink) right.finding.sink
    in
    (match () with
    | () when not (List.equal Int.equal expected_ids actual_ids) -> Error "member IDs do not match the proposed pair"
    | () when List.compare_length_with output.assumptions 0 > 0 -> Error "consolidation has unresolved assumptions"
    | () when not (nonempty output.shared_cause) -> Error "consolidation has no shared cause"
    | () when not (nonempty output.shared_repair) -> Error "consolidation has no shared repair"
    | () when (not (nonempty output.primary_path)) || output.primary_line <= 0 ->
      Error "consolidation has no valid primary anchor"
    | () ->
      Ok
        {
          shared_cause = output.shared_cause;
          shared_repair = output.shared_repair;
          primary_path = output.primary_path;
          primary_line = output.primary_line;
          affected_locations;
          member_finding_ids = actual_ids;
        })
