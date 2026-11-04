let ( let* ) = Result.bind
let default_endpoint = "https://openrouter.ai/api/alpha/decisions"

let endpoint_of_base_url = function
  | None -> default_endpoint
  | Some base_url ->
    let api_root = CCOption.get_or ~default:base_url (CCString.chop_suffix ~suf:"/v1" base_url) in
    api_root ^ "/alpha/decisions"

type t = {
  model : Decision_model.t;
  api_key : string;
  endpoint : string;
}

let create ?(endpoint = default_endpoint) ~model ~api_key () = { model; api_key; endpoint }

let of_secrets ~model (secrets : Config_types.secrets) =
  [ secrets.openrouter_decisions_api_key; secrets.openrouter_api_key ]
  |> List.find_map (fun key -> Stdlib.Option.bind key Llm_provider.nonempty)
  |> Stdlib.Option.map (fun api_key ->
    create ~endpoint:(endpoint_of_base_url (Llm_provider.openrouter_base_url ())) ~model ~api_key ())

let model client = client.model
let thresholds client = Decision_model.thresholds client.model

type noul_question = {
  instructions : string;
  true_criteria : string;
  false_criteria : string;
}

type response = {
  answers : Yojson.Basic.t;
  cost : Cost_tracking.agent_cost;
}

let cost response = response.cost

let question_json { instructions; true_criteria; false_criteria } =
  `Assoc
    [
      "type", `String "noul";
      "instructions", `String instructions;
      "criteria", `Assoc [ "true", `String true_criteria; "false", `String false_criteria ];
    ]

let request_body ~model ~state ~questions =
  `Assoc
    [
      "model", `String (Decision_model.openrouter_id model);
      "state", state;
      "questions", `Assoc (List.map (fun (name, question) -> name, question_json question) questions);
    ]
  |> Yojson.Basic.to_string

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "decision response is missing %S" name))
  | _ -> Error "decision response must be a JSON object"

let typed ~kind extract name value =
  match extract value with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "decision response field %S must be %s" name kind)

let number = function
  | `Float value -> Some value
  | `Int value -> Some (Float.of_int value)
  | _ -> None

let field ~kind extract name json = Result.bind (assoc name json) (typed ~kind extract name)

let string_value name json =
  field ~kind:"a string"
    (function
      | `String value -> Some value
      | _ -> None)
    name json

let int_value name json =
  field ~kind:"an integer"
    (function
      | `Int value -> Some value
      | _ -> None)
    name json

let float_value name json = field ~kind:"a number" number name json

let optional_float_value name json =
  match assoc name json with
  | Error _ | Ok `Null -> Ok None
  | Ok value -> Result.map Stdlib.Option.some (typed ~kind:"a number" number name value)

let response_of_body ~agent_name ~model body =
  let* json =
    match Yojson.Basic.from_string body with
    | json -> Ok json
    | exception Yojson.Json_error message -> Error (Printf.sprintf "invalid decision JSON response: %s" message)
  in
  let* response_model = string_value "model" json in
  let* answers = assoc "answers" json in
  let* usage = assoc "usage" json in
  let* input_tokens = int_value "input_tokens" usage in
  let* output_tokens = int_value "output_tokens" usage in
  let* reported_cost = optional_float_value "cost" usage in
  let estimated_cost_usd =
    match reported_cost with
    | Some cost -> cost
    | None -> Float.of_int input_tokens *. Decision_model.fallback_input_price_per_million model /. 1_000_000.0
  in
  let cost : Cost_tracking.agent_cost =
    {
      agent_name;
      model = response_model;
      input_tokens;
      output_tokens;
      cache_read_input_tokens = 0;
      cache_creation_input_tokens = 0;
      turns = 1;
      files_fetched = 0;
      estimated_cost_usd;
    }
  in
  Ok { answers; cost }

let typed_answer ~expected response name =
  let* answer = assoc name response.answers in
  let* answer_type = string_value "type" answer in
  match String.equal answer_type expected with
  | true -> Ok answer
  | false -> Error (Printf.sprintf "decision answer %S has type %S, expected %S" name answer_type expected)

let noul_answer response name =
  let* answer = typed_answer ~expected:"noul" response name in
  let* probability = float_value "noul" answer in
  match Decision_model.is_probability probability with
  | true -> Ok probability
  | false -> Error (Printf.sprintf "decision model returned out-of-range Noul probability %.4f" probability)

let retryable_status = function
  | 429 | 502 | 503 | 529 -> true
  | _ -> false

(* OpenRouter reports a moderated provider's refusal as a 502 ("OpenAI refused
   to answer question ..."). The same input is refused again, so retrying only
   adds latency. *)
let refusal = function
  | Http_util.Status (502, body) -> String_ext.contains_sub ~sub:"refused to answer" body
  | Http_util.Status _ | Transport _ | Local _ -> false

let rec request client ~body attempt =
  let headers = [ Printf.sprintf "Authorization: Bearer %s" client.api_key ] in
  let%lwt result = Http_util.http_request ~headers ~body:(`Raw ("application/json", body)) `POST client.endpoint in
  match result with
  | Error error when refusal error ->
    Lwt.return (Error (Printf.sprintf "decision model refused: %s" (Http_util.error_to_string error)))
  | Error (Http_util.Status (code, _)) when retryable_status code && attempt < 3 ->
    let%lwt () = Lwt_unix.sleep (0.5 *. (2. ** Float.of_int attempt)) in
    request client ~body (attempt + 1)
  | Ok response -> Lwt.return (Ok response)
  | Error error -> Lwt.return (Error (Http_util.error_to_string error))

let decide client ~agent_name ~state ~questions =
  let body = request_body ~model:client.model ~state ~questions in
  let%lwt response = request client ~body 0 in
  Lwt.return (Result.bind response (response_of_body ~agent_name ~model:client.model))

type noul_output = {
  probability : float;
  cost : Cost_tracking.agent_cost;
}

let score_noul client ~agent_name ~state ~question =
  let%lwt response = decide client ~agent_name ~state ~questions:[ "decision", question ] in
  Lwt.return
    (let* response = response in
     let* probability = noul_answer response "decision" in
     Ok { probability; cost = response.cost })
