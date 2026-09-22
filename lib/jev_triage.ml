open Devkit

let log = Log.from "jev_triage"
let endpoint = "https://api.typesafe.ai/v1/systemone"
let model = "jev-1.13.0"
let input_price_per_million = 0.042
let ( let* ) = Result.bind

let log_context_prefix = function
  | Some context -> context ^ " "
  | None -> ""

type output = {
  signals : Security_types.triage_signal list;
  costs : Cost_tracking.agent_cost list;
  complete : bool;
}

type score = {
  vuln_class : Config_types.vuln_class;
  probability : float;
}

type score_output = {
  scores : score list;
  cost : Cost_tracking.agent_cost;
}

type noul_question = {
  instructions : string;
  true_criteria : string;
  false_criteria : string;
}

type noul_output = {
  probability : float;
  cost : Cost_tracking.agent_cost;
}

type graded_question = {
  instructions : string;
  criteria : string list;
}

type graded_output = {
  score : float;
  confidence : float;
  cost : Cost_tracking.agent_cost;
}

let question = function
  | Config_types.Injection ->
    ( "Does `annotated_diff` warrant dedicated injection analysis because changed code may let untrusted data alter a \
       database query, template expression, interpreter input, or another data-language expression?",
      "The changed code contains a plausible untrusted-data source and interpreter or query sink without clearly \
       adequate contextual parameterization.",
      "The changed code has no plausible injection path, or the only relevant values are constants or clearly use \
       adequate parameterization." )
  | Xss ->
    ( "Does `annotated_diff` warrant dedicated cross-site scripting analysis because changed code may carry untrusted \
       data into HTML, JavaScript, CSS, a browser-executable URL, markdown-rendered HTML, or a response that can later \
       reach one of those browser contexts? Consider multi-step flows, attacker-controlled content types, cookie or \
       JSON reflection, and javascript: links.",
      "The changed code contains a plausible untrusted-data source and browser-executable sink or intermediate \
       representation without clearly adequate context-specific sanitization.",
      "The changed code has no plausible browser-executable data flow, or all relevant data is clearly encoded or \
       sanitized for its eventual browser context." )
  | Command_injection ->
    ( "Does `annotated_diff` warrant dedicated command-injection analysis because changed code may let untrusted data \
       influence a shell command, process invocation, executable, or command argument?",
      "The changed code contains a plausible untrusted-data source and process or shell sink without clearly safe \
       argument handling.",
      "The changed code has no plausible command-execution path, or the command and arguments are fixed or safely \
       separated from untrusted input." )
  | Authn ->
    ( "Does `annotated_diff` warrant dedicated authentication analysis because it changes how identities, credentials, \
       sessions, passwords, API keys, OAuth flows, or tokens are created, checked, or trusted?",
      "The changed code affects an authentication boundary or may accept an identity or credential without every \
       required validation.",
      "The changed code does not affect authentication, or it preserves clearly complete credential and identity \
       validation." )
  | Authz ->
    ( "Does `annotated_diff` warrant dedicated authorization analysis because it changes access control, ownership \
       checks, roles, permissions, or a read or mutation selected by an untrusted resource identifier?",
      "The changed code affects who can perform an action or access a resource, with a plausible missing or weakened \
       permission or ownership check.",
      "The changed code does not affect authorization, or every affected action is clearly constrained by the required \
       permission and resource ownership checks." )
  | Ssrf ->
    ( "Does `annotated_diff` warrant dedicated server-side request forgery analysis because untrusted data may \
       influence the host, scheme, port, path, redirect, or destination of an outbound request?",
      "The changed code contains a plausible untrusted-data source and outbound network sink without a clearly \
       adequate destination allowlist and redirect policy.",
      "The changed code has no plausible attacker-influenced outbound destination, or destinations are clearly and \
       completely constrained." )
  | Path_traversal ->
    ( "Does `annotated_diff` warrant dedicated path-traversal analysis because an untrusted path, filename, or archive \
       member may influence a file read, write, delete, extraction, or response?",
      "The changed code contains a plausible untrusted path component and filesystem sink without a clear \
       resolved-path containment check or safe basename or allowlist reduction.",
      "The changed code has no plausible attacker-controlled filesystem path, or every affected path is clearly \
       confined to the intended location." )
  | Policy_regression ->
    ( "Does `annotated_diff` warrant dedicated security-policy analysis because it may broaden privileges or weaken a \
       security control in IAM, RBAC, CI, deployment, TLS, sandbox, or operating-system configuration?",
      "The changed policy or configuration plausibly grants a broader capability or weakens a named security control.",
      "The change does not broaden privilege or weaken a security control, or it is clearly constrained to the same or \
       a narrower capability." )

let question_json vuln_class =
  let instructions, yes_criteria, no_criteria = question vuln_class in
  ( Security_types.vuln_class_to_string vuln_class,
    `Assoc
      [
        "type", `String "noul";
        "instructions", `String instructions;
        "criteria", `Assoc [ "true", `String yes_criteria; "false", `String no_criteria ];
      ] )

let noul_question_json { instructions; true_criteria; false_criteria } =
  `Assoc
    [
      "type", `String "noul";
      "instructions", `String instructions;
      "criteria", `Assoc [ "true", `String true_criteria; "false", `String false_criteria ];
    ]

let graded_question_json { instructions; criteria } =
  `Assoc
    [
      "type", `String "score";
      "instructions", `String instructions;
      "criteria", `List (List.map (fun criterion -> `String criterion) criteria);
    ]

let status_string = function
  | Diff_parser.Added -> "added"
  | Deleted -> "deleted"
  | Modified -> "modified"
  | Renamed -> "renamed"

let request_body ~vuln_classes ~path ~status ~annotated_diff =
  `Assoc
    [
      "state", `Assoc [ "path", `String path; "status", `String status; "annotated_diff", `String annotated_diff ];
      "model", `String model;
      "questions", `Assoc (List.map question_json vuln_classes);
    ]
  |> Yojson.Basic.to_string

let noul_request_body ~state ~question =
  `Assoc [ "state", state; "model", `String model; "questions", `Assoc [ "decision", noul_question_json question ] ]
  |> Yojson.Basic.to_string

let graded_request_body ~state ~question =
  `Assoc [ "state", state; "model", `String model; "questions", `Assoc [ "decision", graded_question_json question ] ]
  |> Yojson.Basic.to_string

let regions (file_diff : Diff_parser.file_diff) =
  List.filter_map
    (fun (hunk : Diff_parser.hunk) ->
      match hunk.new_count with
      | 0 -> None
      | count ->
        Some
          { Security_types.path = file_diff.path; start_line = hunk.new_start; end_line = hunk.new_start + count - 1 })
    file_diff.hunks

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "Jev response is missing %S" name))
  | _ -> Error "Jev response must be a JSON object"

let string_value name json =
  let open Result in
  let* value = assoc name json in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "Jev response field %S must be a string" name)

let int_value name json =
  let open Result in
  let* value = assoc name json in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "Jev response field %S must be an integer" name)

let float_value name json =
  let open Result in
  let* value = assoc name json in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Printf.sprintf "Jev response field %S must be a number" name)

let probability_value json =
  let open Result in
  let* answer_type = string_value "type" json in
  match String.equal answer_type "noul" with
  | false -> Error (Printf.sprintf "Jev answer has unexpected type %S" answer_type)
  | true ->
    let* value = assoc "noul" json in
    let probability =
      match value with
      | `Float value -> Ok value
      | `Int value -> Ok (Float.of_int value)
      | _ -> Error "Jev Noul probability must be a number"
    in
    let* probability = probability in
    if Float.is_nan probability || probability < 0.0 || probability > 1.0 then
      Error (Printf.sprintf "Jev returned out-of-range Noul probability %.4f" probability)
    else Ok probability

let confidence probability =
  match probability with
  | probability when probability >= 0.8 -> Security_types.High
  | _ -> Medium

let signal ~threshold ~file_diff { vuln_class; probability } =
  if probability < threshold then Ok None
  else (
    let id = Security_types.vuln_class_to_string vuln_class in
    Ok
      (Some
         {
           Security_types.vuln_class;
           confidence = confidence probability;
           regions = regions file_diff;
           rationale = Printf.sprintf "Jev %s routed this file to %s analysis (Noul %.3f)." model id probability;
         }))

let response_parts body =
  let open Result in
  let* json =
    match Yojson.Basic.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error message -> Error (Printf.sprintf "invalid Jev JSON response: %s" message)
  in
  let* response_model = string_value "model" json in
  let* answers = assoc "answers" json in
  let* usage = assoc "usage" json in
  let* input_tokens = int_value "input_tokens" usage in
  let* output_tokens = int_value "output_tokens" usage in
  let cost : Cost_tracking.agent_cost =
    {
      agent_name = "jev_triage";
      model = response_model;
      input_tokens;
      output_tokens;
      cache_read_input_tokens = 0;
      cache_creation_input_tokens = 0;
      turns = 1;
      files_fetched = 0;
      estimated_cost_usd = Float.of_int input_tokens *. input_price_per_million /. 1_000_000.0;
    }
  in
  Ok (answers, cost)

let scores_of_response ~vuln_classes body =
  let open Result in
  let* answers, cost = response_parts body in
  let* scores =
    List.fold_left
      (fun result vuln_class ->
        let* scores = result in
        let id = Security_types.vuln_class_to_string vuln_class in
        let* answer = assoc id answers in
        let* probability = probability_value answer in
        Ok ({ vuln_class; probability } :: scores))
      (Ok []) vuln_classes
  in
  Ok { scores = List.rev scores; cost }

let noul_of_response body =
  let open Result in
  let* answers, cost = response_parts body in
  let* answer = assoc "decision" answers in
  let* probability = probability_value answer in
  Ok { probability; cost }

let graded_output_of_response ~levels body =
  let open Result in
  let* answers, cost = response_parts body in
  let* answer = assoc "decision" answers in
  let* answer_type = string_value "type" answer in
  if not (String.equal answer_type "score") then Error (Printf.sprintf "Jev answer has unexpected type %S" answer_type)
  else
    let* score = float_value "score" answer in
    let* confidence = float_value "confidence" answer in
    let max_score = Float.of_int (levels - 1) in
    match () with
    | () when Float.is_nan score || score < 0.0 || score > max_score ->
      Error (Printf.sprintf "Jev returned out-of-range Score %.4f" score)
    | () when Float.is_nan confidence || confidence < 0.0 || confidence > 1.0 ->
      Error (Printf.sprintf "Jev returned out-of-range Score confidence %.4f" confidence)
    | () -> Ok { score; confidence; cost }

let signals_of_response ~threshold ~vuln_classes ~file_diff body =
  let open Result in
  let* { scores; cost } = scores_of_response ~vuln_classes body in
  let* signals =
    List.fold_left
      (fun result score ->
        let* signals = result in
        let* next = signal ~threshold ~file_diff score in
        match next with
        | Some signal -> Ok (signal :: signals)
        | None -> Ok signals)
      (Ok []) scores
  in
  Ok (List.rev signals, cost)

let retryable_status = function
  | 429 | 529 -> true
  | _ -> false

let rec request ~api_key ~body attempt =
  let headers = [ Printf.sprintf "Authorization: Bearer %s" api_key ] in
  let%lwt result = Http_util.http_request ~headers ~body:(`Raw ("application/json", body)) `POST endpoint in
  match result with
  | Error (Http_util.Status (code, _)) when retryable_status code && attempt < 3 ->
    let delay = 0.5 *. (2. ** Float.of_int attempt) in
    let%lwt () = Lwt_unix.sleep delay in
    request ~api_key ~body (attempt + 1)
  | Ok response -> Lwt.return (Ok response)
  | Error error -> Lwt.return (Error (Http_util.error_to_string error))

let score_context ~api_key ~vuln_classes ~path ~status ~annotated_diff =
  let body = request_body ~vuln_classes ~path ~status ~annotated_diff in
  let%lwt response = request ~api_key ~body 0 in
  Lwt.return (Result.bind response (scores_of_response ~vuln_classes))

let score_noul ~api_key ~state ~question =
  let body = noul_request_body ~state ~question in
  let%lwt response = request ~api_key ~body 0 in
  Lwt.return (Result.bind response noul_of_response)

let score_dimension ~api_key ~state ~question =
  let levels = List.length question.criteria in
  if levels < 2 || levels > 10 then Lwt.return (Error "Jev Score criteria must contain between 2 and 10 levels")
  else (
    let body = graded_request_body ~state ~question in
    let%lwt response = request ~api_key ~body 0 in
    Lwt.return (Result.bind response (graded_output_of_response ~levels)))

let evaluate_file ~api_key ~threshold ~vuln_classes file_diff =
  let%lwt result =
    score_context ~api_key ~vuln_classes ~path:file_diff.Diff_parser.path ~status:(status_string file_diff.status)
      ~annotated_diff:(Diff_parser.to_string_annotated [ file_diff ])
  in
  match result with
  | Error error -> Lwt.return (Error error)
  | Ok { scores; cost } ->
    let open Result in
    let signals =
      List.fold_left
        (fun result score ->
          let* signals = result in
          let* next = signal ~threshold ~file_diff score in
          match next with
          | Some signal -> Ok (signal :: signals)
          | None -> Ok signals)
        (Ok []) scores
    in
    Lwt.return (Result.map (fun signals -> List.rev signals, cost) signals)

let run ?log_context ~api_key ~threshold ~vuln_classes ~diff () =
  if Float.is_nan threshold || threshold < 0.0 || threshold > 1.0 then
    Lwt.return (Error (Printf.sprintf "jev_triage_threshold must be between 0 and 1 (got %.4f)" threshold))
  else (
    let rec loop signals costs succeeded failed first_error = function
      | [] ->
        (match succeeded, first_error with
        | 0, Some error -> Lwt.return (Error error)
        | _, None | _, Some _ ->
          Lwt.return (Ok { signals = List.rev signals; costs = List.rev costs; complete = Int.equal failed 0 }))
      | file_diff :: rest ->
        let%lwt result = evaluate_file ~api_key ~threshold ~vuln_classes file_diff in
        (match result with
        | Ok (file_signals, cost) ->
          loop (List.rev_append file_signals signals) (cost :: costs) (succeeded + 1) failed first_error rest
        | Error error ->
          log#warn "%sJev triage failed for %s: %s" (log_context_prefix log_context) file_diff.Diff_parser.path error;
          let first_error =
            match first_error with
            | Some _ -> first_error
            | None -> Some error
          in
          loop signals costs succeeded (failed + 1) first_error rest)
    in
    match vuln_classes, diff with
    | [], _ | _, [] -> Lwt.return (Ok { signals = []; costs = []; complete = true })
    | _ :: _, _ :: _ -> loop [] [] 0 0 None diff)
