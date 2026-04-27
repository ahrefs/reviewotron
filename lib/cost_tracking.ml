open Devkit
open Melange_json.Primitives

let log = Log.from "cost_tracking"

type model_pricing = {
  model_id_prefix : string;
  input_per_million : float;
  output_per_million : float;
  cache_write_per_million : float;
  cache_read_per_million : float;
}

type agent_cost = {
  agent_name : string;
  model : string;
  input_tokens : int;
  output_tokens : int;
  cache_read_input_tokens : int; [@json.default 0]
  cache_creation_input_tokens : int; [@json.default 0]
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

(** Pricing table — update when Anthropic changes rates.
    Prices in USD per million tokens.  Cache write = 1.25x base input
    (5-minute TTL); cache read = 0.1x base input.
    See https://platform.claude.com/docs/en/about-claude/pricing
    Entries are matched by prefix against model IDs; first match wins. *)
let pricing_table =
  [
    {
      model_id_prefix = "claude-opus-4";
      input_per_million = 5.0;
      output_per_million = 25.0;
      cache_write_per_million = 6.25;
      cache_read_per_million = 0.50;
    };
    {
      model_id_prefix = "claude-sonnet-4";
      input_per_million = 3.0;
      output_per_million = 15.0;
      cache_write_per_million = 3.75;
      cache_read_per_million = 0.30;
    };
    {
      model_id_prefix = "claude-haiku-4";
      input_per_million = 1.0;
      output_per_million = 5.0;
      cache_write_per_million = 1.25;
      cache_read_per_million = 0.10;
    };
  ]

let find_pricing ~model_id =
  List.find_opt (fun p -> String.starts_with ~prefix:p.model_id_prefix model_id) pricing_table

let estimate_cost ~model_id ~input_tokens ~output_tokens ~cache_read_input_tokens ~cache_creation_input_tokens =
  match find_pricing ~model_id with
  | None ->
    log#warn "no pricing found for model %s, using zero cost" model_id;
    0.0
  | Some p ->
    let per_m tokens rate = Float.of_int tokens *. rate /. 1_000_000.0 in
    let input_cost = per_m input_tokens p.input_per_million in
    let output_cost = per_m output_tokens p.output_per_million in
    let cache_write_cost = per_m cache_creation_input_tokens p.cache_write_per_million in
    let cache_read_cost = per_m cache_read_input_tokens p.cache_read_per_million in
    input_cost +. output_cost +. cache_write_cost +. cache_read_cost

let of_agent_result ~agent_name ~files_fetched (result : Agent_runner.agent_result) =
  let input_tokens = result.usage.input_tokens in
  let output_tokens = result.usage.output_tokens in
  let cache_read_input_tokens = result.cache_read_input_tokens in
  let cache_creation_input_tokens = result.cache_creation_input_tokens in
  let model = result.model_id in
  let estimated_cost_usd =
    estimate_cost ~model_id:model ~input_tokens ~output_tokens ~cache_read_input_tokens ~cache_creation_input_tokens
  in
  {
    agent_name;
    model;
    input_tokens;
    output_tokens;
    cache_read_input_tokens;
    cache_creation_input_tokens;
    turns = result.steps_count;
    files_fetched;
    estimated_cost_usd;
  }

let aggregate ~plugin (agents : agent_cost list) =
  let total_input_tokens = List.fold_left (fun acc a -> acc + a.input_tokens) 0 agents in
  let total_output_tokens = List.fold_left (fun acc a -> acc + a.output_tokens) 0 agents in
  let total_estimated_cost_usd = List.fold_left (fun acc a -> acc +. a.estimated_cost_usd) 0.0 agents in
  { plugin; agents; total_input_tokens; total_output_tokens; total_estimated_cost_usd }

let pluralize ~n word = if Int.equal n 1 then word else word ^ "s"

let format_footer (costs : review_cost list) =
  let total_agents = List.fold_left (fun acc c -> acc + List.length c.agents) 0 costs in
  let total_cost = List.fold_left (fun acc c -> acc +. c.total_estimated_cost_usd) 0.0 costs in
  let plugin_parts =
    List.filter_map
      (fun c ->
        let n = List.length c.agents in
        match c.agents with
        | [] -> None
        | _ :: _ -> Some (Printf.sprintf "%s: %d %s" c.plugin n (pluralize ~n "agent")))
      costs
  in
  let details = String.concat ", " plugin_parts in
  Printf.sprintf "\n\n---\n*Review cost: %d %s (%s), ~$%.2f*" total_agents (pluralize ~n:total_agents "agent") details
    total_cost

let log_review_costs (costs : review_cost list) =
  List.iter
    (fun c ->
      List.iter
        (fun a ->
          log#info "cost [%s/%s] model=%s input=%d output=%d cache_read=%d cache_write=%d turns=%d files=%d cost=$%.4f"
            c.plugin a.agent_name a.model a.input_tokens a.output_tokens a.cache_read_input_tokens
            a.cache_creation_input_tokens a.turns a.files_fetched a.estimated_cost_usd)
        c.agents;
      log#info "cost [%s] total: input=%d output=%d cost=$%.4f" c.plugin c.total_input_tokens c.total_output_tokens
        c.total_estimated_cost_usd)
    costs
