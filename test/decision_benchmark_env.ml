(* Shared setup for the decision-model benchmarks: corpus JSON accessors,
   model selection and the OpenRouter client. *)

open Reviewotron_lib

(* Corpus readers fail loudly: a malformed corpus is a benchmark bug. *)
module Corpus_json = struct
  let assoc name = function
    | `Assoc fields ->
      (match List.assoc_opt name fields with
      | Some value -> value
      | None -> failwith (Printf.sprintf "Missing %S" name))
    | _ -> failwith "Expected a JSON object"

  let typed ~kind extract name json =
    match extract (assoc name json) with
    | Some value -> value
    | None -> failwith (Printf.sprintf "%S must be %s" name kind)

  let string name json =
    typed ~kind:"a string"
      (function
        | `String value -> Some value
        | _ -> None)
      name json

  let bool name json =
    typed ~kind:"a boolean"
      (function
        | `Bool value -> Some value
        | _ -> None)
      name json

  let int name json =
    typed ~kind:"an integer"
      (function
        | `Int value -> Some value
        | _ -> None)
      name json
end

let model_of_string name =
  match List.find_opt (fun model -> String.equal (Decision_model.to_string model) name) Decision_model.all with
  | Some model -> model
  | None ->
    raise
      (Arg.Bad
         (Printf.sprintf "unknown decision model %S (expected %s)" name
            (String.concat ", " (List.map Decision_model.to_string Decision_model.all))))

let selected =
  ref (Stdlib.Option.map model_of_string (Stdlib.Option.bind (Sys.getenv_opt "DECISION_MODEL") Llm_provider.nonempty))

let model_spec =
  ( "--model",
    Arg.String (fun name -> selected := Some (model_of_string name)),
    "MODEL Decision model: jev or gpt-6-luna (default jev, or $DECISION_MODEL)" )

let model () = CCOption.get_or ~default:Decision_model.Jev !selected

(* OPENROUTER_DECISIONS_API_KEY, then OPENROUTER_API_KEY, exactly as the
   runtime resolves them. *)
let client () =
  let secrets : Config_types.secrets =
    {
      repos = [];
      anthropic_api_key = None;
      openrouter_api_key = Sys.getenv_opt "OPENROUTER_API_KEY";
      openrouter_decisions_api_key = Sys.getenv_opt "OPENROUTER_DECISIONS_API_KEY";
      slack_access_token = None;
    }
  in
  match Decision_client.of_secrets ~model:(model ()) secrets with
  | Some client -> client
  | None -> failwith "OPENROUTER_DECISIONS_API_KEY or OPENROUTER_API_KEY is required"
