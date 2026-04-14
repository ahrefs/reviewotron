open Devkit

let log = Log.from "state"

(** Maximum number of review records to keep per repo (per category). *)
let max_records_per_repo = 500

type t = {
  mutable data : State_t.state;
  filepath : string option;
}

let empty_state () : State_t.state = { repos = [] }

let create ?filepath () = { data = empty_state (); filepath }

let load ~filepath =
  let data =
    try
      let content = Std.input_file ~bin:true filepath in
      State_j.state_of_string content
    with exn ->
      log#warn "failed to load state from %s: %s, starting fresh" filepath (Exn.str exn);
      empty_state ()
  in
  { data; filepath = Some filepath }

let find_repo_state state ~repo_url =
  match List.assoc_opt repo_url state.State_t.repos with
  | Some rs -> rs
  | None -> { State_t.pr_reviews = []; push_reviews = [] }

let set_repo_state state ~repo_url repo_state =
  let repos = List.filter (fun (url, _) -> not (String.equal url repo_url)) state.State_t.repos in
  { State_t.repos = (repo_url, repo_state) :: repos }

(** Trim a list to at most [n] elements (keeping the most recent, i.e., front of list). *)
let trim_list n lst =
  match List.compare_length_with lst n > 0 with
  | true -> CCList.take n lst
  | false -> lst

let is_pr_reviewed t ~repo_url ~pr_number ~head_sha =
  let rs = find_repo_state t.data ~repo_url in
  List.exists
    (fun (r : State_t.review_record) -> Int.equal r.pr_number pr_number && String.equal r.head_sha head_sha)
    rs.pr_reviews

let record_pr_review t ~repo_url ~pr_number ~head_sha =
  let rs = find_repo_state t.data ~repo_url in
  let now = Time.gmt_string (Unix.gettimeofday ()) in
  let record : State_t.review_record = { pr_number; head_sha; reviewed_at = now } in
  let pr_reviews = trim_list max_records_per_repo (record :: rs.pr_reviews) in
  let rs = { rs with State_t.pr_reviews } in
  t.data <- set_repo_state t.data ~repo_url rs

let is_push_reviewed t ~repo_url ~after_sha =
  let rs = find_repo_state t.data ~repo_url in
  List.exists (fun (r : State_t.push_review_record) -> String.equal r.after_sha after_sha) rs.push_reviews

let record_push_review t ~repo_url ~after_sha =
  let rs = find_repo_state t.data ~repo_url in
  let now = Time.gmt_string (Unix.gettimeofday ()) in
  let record : State_t.push_review_record = { after_sha; reviewed_at = now } in
  let push_reviews = trim_list max_records_per_repo (record :: rs.push_reviews) in
  let rs = { rs with State_t.push_reviews } in
  t.data <- set_repo_state t.data ~repo_url rs

let save t =
  match t.filepath with
  | None -> ()
  | Some path ->
    let json_str = Yojson.Safe.prettify (State_j.string_of_state t.data) in
    (try Files.save_as path (fun oc -> output_string oc json_str)
     with exn -> log#error "failed to save state to %s: %s" path (Exn.str exn))

let data t = t.data
