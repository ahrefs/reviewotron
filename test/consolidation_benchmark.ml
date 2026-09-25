open Reviewotron_lib

type case = {
  name : string;
  expected_consolidate : bool;
  left : Security_types.validated_finding;
  right : Security_types.validated_finding;
  diff_text : string;
}

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
    | Some value -> value
    | None -> failwith (Printf.sprintf "Missing %S" name))
  | _ -> failwith "Expected a JSON object"

let case_of_json json =
  let string name =
    match assoc name json with
    | `String value -> value
    | _ -> failwith (Printf.sprintf "%S must be a string" name)
  in
  let bool name =
    match assoc name json with
    | `Bool value -> value
    | _ -> failwith (Printf.sprintf "%S must be a boolean" name)
  in
  {
    name = string "name";
    expected_consolidate = bool "expected_consolidate";
    left = Security_types.validated_finding_of_json (assoc "left" json);
    right = Security_types.validated_finding_of_json (assoc "right" json);
    diff_text = string "diff_text";
  }

let read_cases path =
  match Yojson.Basic.from_file path with
  | `List cases -> List.map case_of_json cases
  | _ -> failwith "Consolidation corpus must be a JSON array"

let cost_json (result : Agent_runner.agent_result) =
  let cost =
    Cost_tracking.of_agent_result ~agent_name:"consolidation_verifier" ~files_fetched:result.tool_results_count result
  in
  `Assoc
    [
      "model", `String cost.model;
      "input_tokens", `Int cost.input_tokens;
      "output_tokens", `Int cost.output_tokens;
      "files_fetched", `Int cost.files_fetched;
      "cost_usd", `Float cost.estimated_cost_usd;
    ]

let fetch_file root path =
  let components = String.split_on_char '/' path in
  match Filename.is_relative path && not (List.exists (String.equal "..") components) with
  | false -> Lwt.return_error "unsafe path"
  | true ->
    let full_path = Filename.concat root path in
    (match Sys.file_exists full_path && not (Sys.is_directory full_path) with
    | true -> Lwt.return_ok (Some (Std.input_file ~bin:true full_path))
    | false -> Lwt.return_ok None)

let run_case ~ctx ?repo_root case =
  let input =
    Consolidation_agent.build_input ~diff_text:case.diff_text ~left_id:0 ~left:case.left ~right_id:1 ~right:case.right
  in
  let tools = Option.map (fun root -> Consolidation_agent.tools ~fetch_file:(fetch_file root)) repo_root in
  let%lwt result =
    Api_remote.Agent_runner.run ~ctx ~repo_url:"offline://confirmed-consolidation-corpus" ?tools
      ~config:Consolidation_agent.config ~input ()
  in
  let common = [ "name", `String case.name; "expected_consolidate", `Bool case.expected_consolidate ] in
  let json =
    match result with
    | Error error -> `Assoc (common @ [ "error", `String error ])
    | Ok agent_result ->
    match Consolidation_agent.output_of_json agent_result.output with
    | output ->
      let verified, guard_reason =
        match Consolidation_agent.verify ~left_id:0 ~left:case.left ~right_id:1 ~right:case.right output with
        | Ok _ -> true, None
        | Error reason -> false, Some reason
      in
      let fields =
        common
        @ [ "verified_consolidation", `Bool verified; "output", agent_result.output; "cost", cost_json agent_result ]
      in
      let fields =
        match guard_reason with
        | Some reason -> fields @ [ "guard_reason", `String reason ]
        | None -> fields
      in
      `Assoc fields
    | exception exn ->
      `Assoc
        (common
        @ [ "error", `String (Devkit.Exn.str exn); "output", agent_result.output; "cost", cost_json agent_result ])
  in
  print_endline (Yojson.Basic.to_string json);
  flush stdout;
  Lwt.return_unit

let main corpus secrets repo_root =
  let ctx =
    match Context.create ~secrets_filepath:secrets ~require_repos:false () with
    | Ok ctx -> ctx
    | Error error -> failwith error
  in
  Lwt_list.iter_s (run_case ~ctx ?repo_root) (read_cases corpus)

let () =
  match Array.to_list Sys.argv with
  | [ _; corpus; secrets ] -> Lwt_main.run (main corpus secrets None)
  | [ _; corpus; secrets; repo_root ] -> Lwt_main.run (main corpus secrets (Some repo_root))
  | _ -> failwith "Usage: consolidation_benchmark CORPUS SECRETS [REPO_ROOT]"
