(** State persistence types: tracks reviewed changes. *)

type review_record = {
  pr_number : int;
  head_sha : string;
  reviewed_at : string;
  review_costs : Cost_tracking.review_cost list;
}
[@@deriving json]

type push_review_record = {
  after_sha : string;
  reviewed_at : string;
}
[@@deriving json]

type change_review_record = {
  change_key : string;
  reviewed_at : string;
  review_costs : Cost_tracking.review_cost list;
}
[@@deriving json]

type repo_state = {
  pr_reviews : review_record list;
  push_reviews : push_review_record list;
  change_reviews : change_review_record list;
}
[@@deriving json]

type state = { repos : (string * repo_state) list }

val state_to_json : state -> Yojson.Basic.t
val state_of_json : Yojson.Basic.t -> state
