open Reviewotron_lib

type file_case = {
  path : string;
  status : string;
  annotated_diff : string;
}

type review_case = {
  name : string;
  files : file_case list;
}

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
    | Some value -> value
    | None -> failwith (Printf.sprintf "Missing %S" name))
  | _ -> failwith "Expected a JSON object"

let string name json =
  match assoc name json with
  | `String value -> value
  | _ -> failwith (Printf.sprintf "%S must be a string" name)

let file_case_of_json json =
  { path = string "path" json; status = string "status" json; annotated_diff = string "annotated_diff" json }

let review_case_of_json json =
  let files =
    match assoc "files" json with
    | `List files -> List.map file_case_of_json files
    | _ -> failwith "files must be an array"
  in
  { name = string "name" json; files }

let read_cases path =
  match Yojson.Basic.from_file path with
  | `List cases -> List.map review_case_of_json cases
  | _ -> failwith "Captured routing corpus must be a JSON array"

let vuln_classes = Config_types.all_vuln_classes

let emit review file = function
  | Error error -> `Assoc [ "review", `String review.name; "path", `String file.path; "error", `String error ]
  | Ok (output : Jev_triage.score_output) ->
    `Assoc
      [
        "review", `String review.name;
        "path", `String file.path;
        ( "scores",
          `Assoc
            (List.map
               (fun (score : Jev_triage.score) ->
                 Security_types.vuln_class_to_string score.vuln_class, `Float score.probability)
               output.scores) );
        "input_tokens", `Int output.cost.input_tokens;
        "cost_usd", `Float output.cost.estimated_cost_usd;
      ]

let run_file ~api_key review file =
  let%lwt result =
    Jev_triage.score_context ~api_key ~vuln_classes ~path:file.path ~status:file.status
      ~annotated_diff:file.annotated_diff
  in
  print_endline (Yojson.Basic.to_string (emit review file result));
  flush stdout;
  Lwt.return_unit

let main corpus =
  let api_key =
    match Sys.getenv_opt "TYPESAFE_API_KEY" with
    | Some value when not (String.equal (String.trim value) "") -> value
    | Some _ | None -> failwith "TYPESAFE_API_KEY is required"
  in
  Lwt_list.iter_s (fun review -> Lwt_list.iter_s (run_file ~api_key review) review.files) (read_cases corpus)

let () =
  match Array.to_list Sys.argv with
  | [ _; corpus ] -> Lwt_main.run (main corpus)
  | _ -> failwith "Usage: jev_captured_routing_benchmark CORPUS"
