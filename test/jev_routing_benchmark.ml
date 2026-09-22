open Reviewotron_lib

type arm =
  | Per_file
  | Per_hunk
  | Whole_diff

type case = {
  name : string;
  expected_class : Config_types.vuln_class;
  vulnerable : bool;
  diff : Diff_parser.t;
}

type context = {
  unit_name : string;
  path : string;
  status : string;
  annotated_diff : string;
}

let arm_name = function
  | Per_file -> "per_file"
  | Per_hunk -> "per_hunk"
  | Whole_diff -> "whole_diff"

let status_string = function
  | Diff_parser.Added -> "added"
  | Deleted -> "deleted"
  | Modified -> "modified"
  | Renamed -> "renamed"

let has_suffix ~suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length && String.equal suffix (String.sub value (value_length - suffix_length) suffix_length)

let class_directories =
  [
    "injection", Config_types.Injection;
    "xss", Xss;
    "command_injection", Command_injection;
    "authn", Authn;
    "authz", Authz;
    "ssrf", Ssrf;
    "path_traversal", Path_traversal;
    "policy_regression", Policy_regression;
  ]

let read_cases corpus =
  class_directories
  |> List.concat_map (fun (directory, expected_class) ->
    let root = Filename.concat corpus directory in
    Sys.readdir root
    |> Array.to_list
    |> List.filter (has_suffix ~suffix:".diff")
    |> List.sort String.compare
    |> List.map (fun filename ->
      let path = Filename.concat root filename in
      let diff = Diff_parser.parse (Std.input_file ~bin:true path) in
      if List.is_empty diff then failwith (Printf.sprintf "No diff parsed from %s" path);
      {
        name = Filename.concat directory filename;
        expected_class;
        vulnerable = not (has_suffix ~suffix:"_safe.diff" filename);
        diff;
      }))

let file_context (file_diff : Diff_parser.file_diff) =
  {
    unit_name = file_diff.path;
    path = file_diff.path;
    status = status_string file_diff.status;
    annotated_diff = Diff_parser.to_string_annotated [ file_diff ];
  }

let contexts arm case =
  match arm with
  | Per_file -> List.map file_context case.diff
  | Per_hunk ->
    case.diff
    |> List.concat_map (fun (file_diff : Diff_parser.file_diff) ->
      List.mapi
        (fun index hunk ->
          let context = file_context { file_diff with hunks = [ hunk ] } in
          { context with unit_name = Printf.sprintf "%s#%d" file_diff.path (index + 1) })
        file_diff.hunks)
  | Whole_diff ->
    [
      {
        unit_name = "whole_diff";
        path = String.concat "," (List.map (fun (file_diff : Diff_parser.file_diff) -> file_diff.path) case.diff);
        status = "mixed";
        annotated_diff = Diff_parser.to_string_annotated case.diff;
      };
    ]

let score_json (score : Jev_triage.score) =
  Security_types.vuln_class_to_string score.vuln_class, `Float score.probability

let emit_result ~case ~arm ~repetition ~context ~elapsed result =
  let common =
    [
      "case", `String case.name;
      "expected_class", `String (Security_types.vuln_class_to_string case.expected_class);
      "vulnerable", `Bool case.vulnerable;
      "arm", `String (arm_name arm);
      "repetition", `Int repetition;
      "unit", `String context.unit_name;
      "elapsed_ms", `Float (elapsed *. 1000.0);
    ]
  in
  let json =
    match result with
    | Error error -> `Assoc (("error", `String error) :: common)
    | Ok ({ scores; cost } : Jev_triage.score_output) ->
      `Assoc
        (("scores", `Assoc (List.map score_json scores))
        :: ("input_tokens", `Int cost.input_tokens)
        :: ("cost_usd", `Float cost.estimated_cost_usd)
        :: common)
  in
  print_endline (Yojson.Basic.to_string json);
  flush stdout

let run_context ~api_key ~case ~arm ~repetition context =
  let started = Unix.gettimeofday () in
  let%lwt result =
    Jev_triage.score_context ~api_key ~vuln_classes:Config_types.all_vuln_classes ~path:context.path
      ~status:context.status ~annotated_diff:context.annotated_diff
  in
  emit_result ~case ~arm ~repetition ~context ~elapsed:(Unix.gettimeofday () -. started) result;
  Lwt.return_unit

let run ~api_key ~repeats cases =
  let arms = [ Per_file; Per_hunk; Whole_diff ] in
  Lwt_list.iter_s
    (fun case ->
      Lwt_list.iter_s
        (fun arm ->
          let rec repeat repetition =
            if repetition > repeats then Lwt.return_unit
            else (
              let%lwt () = Lwt_list.iter_s (run_context ~api_key ~case ~arm ~repetition) (contexts arm case) in
              repeat (repetition + 1))
          in
          repeat 1)
        arms)
    cases

let self_test cases =
  let vulnerable, safe = List.partition (fun case -> case.vulnerable) cases in
  if List.is_empty vulnerable || List.is_empty safe then failwith "Corpus needs vulnerable and safe cases";
  let cross_file = List.exists (fun case -> List.compare_length_with case.diff 2 >= 0) cases in
  if not cross_file then failwith "Corpus needs a cross-file case";
  let multi_hunk =
    List.exists
      (fun case ->
        List.exists
          (fun (file_diff : Diff_parser.file_diff) -> List.compare_length_with file_diff.hunks 2 >= 0)
          case.diff)
      cases
  in
  if not multi_hunk then failwith "Corpus needs a multi-hunk case";
  Printf.printf "ok: %d cases (%d vulnerable, %d safe)\n" (List.length cases) (List.length vulnerable)
    (List.length safe)

let () =
  let corpus = ref "test/security_corpus" in
  let repeats = ref 5 in
  let self_test_only = ref false in
  Arg.parse
    [
      "--corpus", Arg.Set_string corpus, "DIR Security corpus directory";
      "--repeats", Arg.Set_int repeats, "N Repetitions per context";
      "--self-test", Arg.Set self_test_only, "Validate benchmark inputs without API calls";
    ]
    (fun argument -> raise (Arg.Bad (Printf.sprintf "Unexpected argument: %s" argument)))
    "jev_routing_benchmark [options]";
  let cases = read_cases !corpus in
  match !self_test_only with
  | true -> self_test cases
  | false ->
    if !repeats < 1 then raise (Arg.Bad "--repeats must be positive");
    let api_key =
      match Sys.getenv_opt "TYPESAFE_API_KEY" with
      | Some api_key when not (String.equal (String.trim api_key) "") -> api_key
      | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
    in
    Lwt_main.run (run ~api_key ~repeats:!repeats cases)
