open Devkit

let log = Log.from "github_auth"

type token = string

(** {2 JWT generation for GitHub App authentication} *)

let b64url_encode s = Base64.encode_string ~alphabet:Base64.uri_safe_alphabet ~pad:false s

let make_jwt ~client_id ~pem =
  let now = Unix.gettimeofday () in
  (* Issued 60 seconds in the past to allow for clock drift *)
  let iat = int_of_float (now -. 60.0) in
  (* JWT expires in 1 minute — only used to exchange for an installation token *)
  let exp = int_of_float (now +. 60.0) in
  let header_json = {|{"typ":"JWT","alg":"RS256"}|} in
  let payload_json = Printf.sprintf {|{"iat":%d,"exp":%d,"iss":"%s"}|} iat exp client_id in
  let header_payload = Printf.sprintf "%s.%s" (b64url_encode header_json) (b64url_encode payload_json) in
  match X509.Private_key.decode_pem pem with
  | Ok (`RSA key) ->
    let signature = Mirage_crypto_pk.Rsa.PKCS1.sign ~hash:`SHA256 ~key (`Message header_payload) |> b64url_encode in
    Ok (Printf.sprintf "%s.%s" header_payload signature)
  | Ok _ -> Error "expected RSA private key for GitHub App authentication"
  | Error (`Msg msg) -> Error (Printf.sprintf "failed to parse GitHub App private key: %s" msg)

(** {2 Installation token cache}

    GitHub App installation tokens are valid for 1 hour. We cache them for
    50 minutes to avoid using tokens that are about to expire. *)

type cached_token = {
  token : string;
  expires_at : float;
}

(* Keyed by installation_id *)
let token_cache : (string, cached_token) Hashtbl.t = Hashtbl.create 4

let cache_ttl_seconds = 50.0 *. 60.0

let invalidate_cache () = Hashtbl.clear token_cache

let find_cached_token ~installation_id =
  match Hashtbl.find_opt token_cache installation_id with
  | Some entry when Unix.gettimeofday () < entry.expires_at -> Some entry.token
  | Some _ ->
    Hashtbl.remove token_cache installation_id;
    None
  | None -> None

let cache_token ~installation_id tok =
  let entry = { token = tok; expires_at = Unix.gettimeofday () +. cache_ttl_seconds } in
  Hashtbl.replace token_cache installation_id entry

(** {2 Installation token exchange} *)

let exchange_installation_token (app : Config_types.app_installation_cfg) =
  match make_jwt ~client_id:app.client_id ~pem:app.pem with
  | Error _ as e -> Lwt.return e
  | Ok jwt ->
    let url = Printf.sprintf "https://api.github.com/app/installations/%s/access_tokens" app.installation_id in
    let headers = [ "Accept: application/vnd.github.v3+json"; Printf.sprintf "Authorization: Bearer %s" jwt ] in
    let%lwt result = Http_util.http_request ~headers ~body:(`Raw ("application/json", "")) `POST url in
    (match result with
    | Error e ->
      let msg = Printf.sprintf "error exchanging installation token: %s" (Http_util.error_to_string e) in
      log#error "%s" msg;
      Lwt.return (Error msg)
    | Ok body ->
    match Github_types.installation_token_response_of_json (Melange_json.of_string body) with
    | resp ->
      cache_token ~installation_id:app.installation_id resp.token;
      log#info "obtained installation token for installation %s" app.installation_id;
      Lwt.return (Ok resp.token)
    | exception exn ->
      Lwt.return (Error (Printf.sprintf "failed to parse installation token response: %s" (Exn.str exn))))

(** {2 Public API} *)

let get_token (auth : Config_types.repo_auth) =
  match auth with
  | GH_token token -> Lwt.return (Ok token)
  | AppInstallation app ->
  match find_cached_token ~installation_id:app.installation_id with
  | Some tok -> Lwt.return (Ok tok)
  | None -> exchange_installation_token app

let auth_header auth =
  let%lwt result = get_token auth in
  match result with
  | Ok tok ->
    let scheme =
      match auth with
      | GH_token _ -> "token"
      | AppInstallation _ -> "Bearer"
    in
    Lwt.return (Ok ("Authorization", Printf.sprintf "%s %s" scheme tok))
  | Error _ as e -> Lwt.return e
