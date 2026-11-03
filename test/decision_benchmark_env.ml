(* Shared setup for the decision-model benchmarks: model selection and the
   OpenRouter client. *)

open Reviewotron_lib

let model_of_string name =
  match List.find_opt (fun model -> String.equal (Decision_model.to_string model) name) Decision_model.all with
  | Some model -> model
  | None ->
    raise
      (Arg.Bad
         (Printf.sprintf "unknown decision model %S (expected %s)" name
            (String.concat ", " (List.map Decision_model.to_string Decision_model.all))))

let selected =
  ref
    (match Sys.getenv_opt "DECISION_MODEL" with
    | Some name when not (String.equal (String.trim name) "") -> Some (model_of_string (String.trim name))
    | Some _ | None -> None)

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
