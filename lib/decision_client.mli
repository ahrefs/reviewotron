(** Client for OpenRouter's Decisions API ([POST /api/alpha/decisions]).

    Every decision model on OpenRouter takes the same request: a [state] to
    judge and a map of named questions. Reviewotron asks only Noul questions,
    each of which returns one probability. *)

type t

(** Derive the Decisions endpoint from an OpenRouter base URL such as
    [https://openrouter.ai/api/v1]: a trailing [/v1] is replaced with
    [/alpha/decisions]. [None] gives OpenRouter's public endpoint. *)
val endpoint_of_base_url : string option -> string

(** [on_by_default] (default [false]) is what {!enabled} and {!triage_mode}
    use for unset settings. *)
val create : ?endpoint:string -> ?on_by_default:bool -> model:Decision_model.t -> api_key:string -> unit -> t

(** Build a client from the decisions-only OpenRouter key, falling back to the
    general OpenRouter key. The endpoint follows [OPENROUTER_BASE_URL]. [None]
    when neither key is set. Decision features are on by default when the
    review's LLM provider is OpenRouter, and opt-in for other providers. *)
val of_secrets : model:Decision_model.t -> Config_types.secrets -> t option

(** Whether a decision feature runs. An explicit setting wins; [None] follows
    the client's provider default, and is off without a client. *)
val enabled : t option -> bool option -> bool

(** The security triage mode. An explicit setting wins; [None] is [Gate] when
    decision features are on by default and [Off] otherwise. *)
val triage_mode : t option -> Config_types.decision_triage_mode option -> Config_types.decision_triage_mode

val model : t -> Decision_model.t

(** The calibrated thresholds of the client's model. *)
val thresholds : t -> Decision_model.thresholds

(** Whether a failed request is a moderated provider's refusal, which
    OpenRouter reports as a 502 and which a retry would only repeat. *)
val refusal : Http_util.error -> bool

type noul_question = {
  instructions : string;
  true_criteria : string;
  false_criteria : string;
}

(** Answers keyed by question name, plus the call's cost. *)
type response

val cost : response -> Cost_tracking.agent_cost

(** Serialize one request. Exposed for wire-format tests. *)
val request_body : model:Decision_model.t -> state:Yojson.Basic.t -> questions:(string * noul_question) list -> string

(** Parse one successful response body. Cost comes from [usage.cost] when
    present, otherwise from the model's input price, and is reported under
    [agent_name]. *)
val response_of_body : agent_name:string -> model:Decision_model.t -> string -> (response, string) result

(** The probability answered for a named Noul question. *)
val noul_answer : response -> string -> (float, string) result

(** Send one request, retrying rate limits and transient upstream failures.
    The call's cost is reported under [agent_name]. *)
val decide :
  t ->
  agent_name:string ->
  state:Yojson.Basic.t ->
  questions:(string * noul_question) list ->
  (response, string) result Lwt.t

type noul_output = {
  probability : float;
  cost : Cost_tracking.agent_cost;
}

(** Ask one Noul question. *)
val score_noul :
  t -> agent_name:string -> state:Yojson.Basic.t -> question:noul_question -> (noul_output, string) result Lwt.t
