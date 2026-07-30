(** Per-agent and per-review cost tracking.

    Computes estimated USD cost from token usage and model pricing.
    The pricing table is a single, easily-updated record in the codebase. *)

type agent_cost = {
  agent_name : string;
  model : string;
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int;
  cache_creation_input_tokens : int;
  turns : int;
  files_fetched : int;
  estimated_cost_usd : float;
}
[@@deriving json]

type review_cost = {
  plugin : string;
  agents : agent_cost list;
  total_input_tokens : int;
  total_output_tokens : int;
  total_estimated_cost_usd : float;
}
[@@deriving json]

(** Estimate the USD cost for a given model and token counts.
    Includes cache write (1.25x base input) and cache read (0.1x base input)
    pricing when cache tokens are present.
    Returns [0.0] if the model ID is not recognized (with a warning logged).

    The three input buckets ([input_tokens], [cache_read_input_tokens],
    [cache_creation_input_tokens]) are assumed DISJOINT — each prompt token is
    counted in exactly one. {!Agent_runner} guarantees this on both providers
    (it subtracts the cached portion out of [input_tokens] on the OpenRouter
    path, where the provider otherwise double-reports it). *)
val estimate_cost :
  model_id:string ->
  input_tokens:int ->
  output_tokens:int ->
  cache_read_input_tokens:int ->
  cache_creation_input_tokens:int ->
  float

(** Build an {!agent_cost} from an agent result.

    @param agent_name identifies the agent (e.g. ["triage"], ["injection_analysis"])
    @param log_context prefixes pricing warnings for concurrent review log correlation
    @param files_fetched number of [get_file_content] tool calls the agent made *)
val of_agent_result :
  ?log_context:string -> agent_name:string -> files_fetched:int -> Agent_runner.agent_result -> agent_cost

(** Aggregate a list of per-agent costs into a per-plugin summary. *)
val aggregate : plugin:string -> agent_cost list -> review_cost

(** [pluralize ~n word] appends ["s"] unless [n] is 1. *)
val pluralize : n:int -> string -> string

(** Format an optional review footer showing review cost.
    Returns a markdown string like ["Review cost: 3 agents, ~$0.42"]. *)
val format_footer : review_cost list -> string

(** Log all agent costs at info level.

    [log_context], when supplied, prefixes each line so concurrent review logs
    can be correlated. *)
val log_review_costs : ?log_context:string -> review_cost list -> unit
