(** Client for OpenRouter's Decisions API ([POST /api/alpha/decisions]).

    Every decision model on OpenRouter takes the same request: a [state] to
    judge and a map of named questions. A Noul question returns one
    probability; a Score question returns a probability-weighted level and a
    confidence. *)

type t

(** Endpoint used when [OPENROUTER_BASE_URL] is unset. *)
val default_endpoint : string

(** Derive the Decisions endpoint from an OpenRouter base URL such as
    [https://openrouter.ai/api/v1]: a trailing [/v1] is replaced with
    [/alpha/decisions]. [None] gives {!default_endpoint}. *)
val endpoint_of_base_url : string option -> string

val create : ?endpoint:string -> model:Decision_model.t -> api_key:string -> unit -> t

(** Build a client from the decisions-only OpenRouter key, falling back to the
    general OpenRouter key. The endpoint follows [OPENROUTER_BASE_URL]. [None]
    when neither key is set. *)
val of_secrets : model:Decision_model.t -> Config_types.secrets -> t option

val model : t -> Decision_model.t

(** [threshold client configured select] is [configured] when set, otherwise
    the field [select] picks from the client's calibrated model thresholds. *)
val threshold : t -> float option -> (Decision_model.thresholds -> float) -> float

(** Whether a failed request is a moderated provider's refusal, which
    OpenRouter reports as a 502 and which a retry would only repeat. *)
val refusal : Http_util.error -> bool

type noul_question = {
  instructions : string;
  true_criteria : string;
  false_criteria : string;
}

type graded_question = {
  instructions : string;
  criteria : string list;  (** Ordered levels, lowest first. *)
}

type question =
  | Noul of noul_question
  | Score of graded_question

(** Answers keyed by question name, plus the call's cost. *)
type response

val cost : response -> Cost_tracking.agent_cost

(** Serialize one request. Exposed for wire-format tests. *)
val request_body : model:Decision_model.t -> state:Yojson.Basic.t -> questions:(string * question) list -> string

(** Parse one successful response body. Cost comes from [usage.cost] when
    present, otherwise from the model's input price. *)
val response_of_body : model:Decision_model.t -> string -> (response, string) result

(** The probability answered for a named Noul question. *)
val noul_answer : response -> string -> (float, string) result

(** The score and confidence answered for a named Score question with [levels]
    levels. *)
val score_answer : levels:int -> response -> string -> (float * float, string) result

(** Send one request, retrying rate limits and transient upstream failures. *)
val decide : t -> state:Yojson.Basic.t -> questions:(string * question) list -> (response, string) result Lwt.t

type noul_output = {
  probability : float;
  cost : Cost_tracking.agent_cost;
}

type graded_output = {
  score : float;
  confidence : float;
  cost : Cost_tracking.agent_cost;
}

(** Ask one Noul question. *)
val score_noul : t -> state:Yojson.Basic.t -> question:noul_question -> (noul_output, string) result Lwt.t

(** Rate [state] along one ordered dimension of 2 to 10 levels. *)
val score_dimension : t -> state:Yojson.Basic.t -> question:graded_question -> (graded_output, string) result Lwt.t

(** Parse one successful single-question Score response. *)
val graded_output_of_body : model:Decision_model.t -> levels:int -> string -> (graded_output, string) result
