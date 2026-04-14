open Devkit

type t = {
  config_filename : string;
  secrets : Config_t.secrets;
  repo_configs : (string, Config_t.config) Hashtbl.t;
  state : State.t;
}

let default_secrets_filepath = "secrets.json"
let default_config_filename = ".reviewotron.json"

let default_config () : Config_t.config = Config_j.config_of_string "{}"

let load_secrets ~secrets_filepath =
  match Config_j.secrets_of_string (Std.input_file ~bin:true secrets_filepath) with
  | exception exn ->
    let msg = Printf.sprintf "failed to read secrets from %s: %s" secrets_filepath (Exn.str exn) in
    Error msg
  | secrets ->
  match secrets.repos with
  | [] -> Error (Printf.sprintf "at least one repo must be specified in %s" secrets_filepath)
  | _ :: _ -> Ok secrets

let create ~secrets_filepath ?config_filename ?state_filepath () =
  match load_secrets ~secrets_filepath with
  | Error e -> Error e
  | Ok secrets ->
    let config_filename = Option.default default_config_filename config_filename in
    let state =
      match state_filepath with
      | Some path -> State.load ~filepath:path
      | None -> State.create ()
    in
    Ok { config_filename; secrets; repo_configs = Hashtbl.create 16; state }

let find_repo_config ctx ~repo_url = Hashtbl.find_opt ctx.repo_configs repo_url

let set_repo_config ctx ~repo_url config = Hashtbl.replace ctx.repo_configs repo_url config

let get_config ctx ~repo_url =
  match find_repo_config ctx ~repo_url with
  | Some config -> config
  | None -> default_config ()

let find_secrets_repo ctx ~repo_url =
  List.find_opt (fun (repo : Config_t.repo_config) -> String.equal repo.url repo_url) ctx.secrets.repos

let get_hook_secret ctx ~repo_url =
  Stdlib.Option.bind (find_secrets_repo ctx ~repo_url) (fun repo -> repo.gh_hook_secret)

let get_repo_auth ctx ~repo_url =
  Stdlib.Option.bind (find_secrets_repo ctx ~repo_url) (fun (repo : Config_t.repo_config) -> repo.auth)

let get_gh_token ctx ~repo_url =
  match get_repo_auth ctx ~repo_url with
  | Some (GH_token tok) -> Some tok
  | Some (AppInstallation _) -> None
  | None -> None

let secrets ctx = ctx.secrets
let state ctx = ctx.state
let config_filename ctx = ctx.config_filename

let make ~secrets ?config_filename ?state () =
  let config_filename = Option.default default_config_filename config_filename in
  let state =
    match state with
    | Some s -> s
    | None -> State.create ()
  in
  { config_filename; secrets; repo_configs = Hashtbl.create 16; state }
