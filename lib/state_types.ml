(** State persistence types: tracks which PRs and pushes have been reviewed. *)

open Melange_json.Primitives

type review_record = {
  pr_number : int;
  head_sha : string;
  reviewed_at : string;
}
[@@deriving json]

type push_review_record = {
  after_sha : string;
  reviewed_at : string;
}
[@@deriving json]

type repo_state = {
  pr_reviews : review_record list; [@json.default []]
  push_reviews : push_review_record list; [@json.default []]
}
[@@deriving json]

type state = { repos : (string * repo_state) list }

(** Serialize state to JSON. The [repos] field uses object representation
    for backward compatibility with the ATD [<json repr="object">] format:
    each key is a repo URL, each value is the repo state. *)
let state_to_json (s : state) : Yojson.Basic.t =
  let repos_json = List.map (fun (url, rs) -> url, repo_state_to_json rs) s.repos in
  `Assoc [ "repos", `Assoc repos_json ]

let state_of_json (json : Yojson.Basic.t) : state =
  match json with
  | `Assoc fields ->
    let repos =
      match List.assoc_opt "repos" fields with
      | Some (`Assoc pairs) -> List.map (fun (url, v) -> url, repo_state_of_json v) pairs
      | Some json -> Melange_json.of_json_error ~json "expected object for \"repos\""
      | None -> []
    in
    { repos }
  | json -> Melange_json.of_json_error ~json "expected a JSON object"
