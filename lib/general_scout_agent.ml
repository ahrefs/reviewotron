(** General review scout — first stage of the general review pipeline.

    Reads the change diff and emits capped investigation leads for the
    deep reviewer.  Biased toward over-flagging: a missed lead is
    unrecoverable downstream; a bogus lead costs one paragraph of deep
    review.  Never emits style/naming/documentation leads, and skips
    security leads when the security plugin covers them. *)

let log = Devkit.Log.from "general_scout"

let log_context_prefix = function
  | None -> ""
  | Some context -> context ^ " "

(* Parcel of the system prompt whose wording depends on whether a dedicated
   security pipeline is already reviewing this change.  Mirrors how
   {!Review_prompt.build_system_prompt} toggles its security focus. *)
let security_section ~security_covered_elsewhere =
  match security_covered_elsewhere with
  | true ->
    {|- Security vulnerabilities (injection, XSS, authn/authz, SSRF, secrets):
  a dedicated security pipeline reviews this change; do not duplicate it.|}
  | false ->
    {|Security-relevant changes (injection, XSS, authn/authz, SSRF, secrets
handling) ARE valid leads — flag them with category "security".|}

let security_category ~security_covered_elsewhere =
  match security_covered_elsewhere with
  | true -> ""
  | false -> ", security"

let build_system_prompt ~security_covered_elsewhere =
  Printf.sprintf
    {|You are a code-review scout. You read a change diff and produce a list of
investigation leads for a deep reviewer. You do NOT verify, you NOTICE.

## Posture

Bias toward over-flagging. It is cheap for the deep reviewer to dismiss a
lead; it is expensive to miss a real defect because no lead pointed at it.
When in doubt, emit the lead. But every lead must name a concrete, checkable
hypothesis — "this function looks complex" is not a lead.

## What makes a good lead

- Deleted or weakened guarantees: removed checks, dropped error branches,
  narrowed retries/timeouts/locks, behavior removed while callers still
  depend on it.
- Cross-boundary drift: an interface, schema, enum, or contract changed in
  one place while siblings/callers/implementations visible in the diff (or
  clearly implied by it) were not updated.
- Silent behavior changes: same signature, different semantics — changed
  defaults, reordered operations, altered rounding/encoding/timezone/null
  handling.
- Unhandled cases introduced by the change: new enum variants, new error
  paths, new inputs that existing branches don't cover.
- Suspicious edits: off-by-one candidates, inverted conditions, swapped
  arguments, copy-paste with a missed rename, resource acquired but not
  released on a new path.
- Concurrency and lifecycle: new shared mutable state, lock scope changes,
  async operations whose failure or cancellation is now unobserved.
- Material performance regressions: new work inside hot loops, N+1 patterns,
  unbounded growth.

## What is NEVER a lead

- Style, formatting, naming, documentation, comment wording.
- Praise or "consider" suggestions without a failure hypothesis.
- Pre-existing problems the diff neither touches nor worsens.
- Missing tests, unless a specific broken input/branch can be named.
%s

## Output

Produce a JSON object matching the schema:
- `leads`: array of {path, line, end_line?, hypothesis, category, confidence}.
  * `path`/`line` copied verbatim from the annotated diff's file headers and
    left-column line numbers — never estimated.
  * `hypothesis`: one or two sentences: what might be wrong, and what the deep
    reviewer should check to confirm or refute it.
  * `category`: one of the finding categories (bug, logic, error_handling,
    performance%s).
  * `confidence`: high | medium | low — your confidence the lead deserves deep
    review, not that it's a confirmed defect.
- `skip_note`: one line naming the parts of the diff you deliberately did not
  flag and why (e.g. "test-only churn, generated lockfile"). Empty string if
  nothing was skipped.

Order leads by confidence, highest first. Emit an empty `leads` array when the
change genuinely warrants no deep review — an honest empty scout report is
valuable. Your final response must be a single JSON object matching the schema,
no markdown fences, no prose.|}
    (security_section ~security_covered_elsewhere)
    (security_category ~security_covered_elsewhere)

(* Sized for a single-shot scout that emits a small list of leads with a
   private reasoning channel; tune here without touching call sites. *)
let scout_thinking_budget = 2048

let config ~model_tier ~security_covered_elsewhere : Agent_runner.agent_config =
  {
    name = "general_scout";
    system_prompt = build_system_prompt ~security_covered_elsewhere;
    model_tier;
    output_schema = Review_types.scout_output_jsonschema;
    max_steps = 1;
    thinking_budget = Some scout_thinking_budget;
  }

let build_input ~diff_text ~change_title ~change_description () =
  let buf = Buffer.create (String.length diff_text + 512) in
  Printf.bprintf buf "## Change: %s\n\n" change_title;
  (match String.length change_description > 0 with
  | true ->
    Buffer.add_string buf change_description;
    Buffer.add_string buf "\n\n"
  | false -> ());
  Buffer.add_string buf Review_prompt.annotated_diff_format_explainer;
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf

let cap_leads ?log_context ~max_leads (leads : Review_types.scout_lead list) =
  let ranked =
    List.stable_sort
      (fun (a : Review_types.scout_lead) (b : Review_types.scout_lead) ->
        Int.compare (Config_types.confidence_rank b.confidence) (Config_types.confidence_rank a.confidence))
      leads
  in
  let kept, dropped = CCList.take_drop max_leads ranked in
  (match dropped with
  | [] -> ()
  | _ :: _ ->
    let log_prefix = log_context_prefix log_context in
    let dropped_locations =
      dropped
      |> List.map (fun (l : Review_types.scout_lead) -> Printf.sprintf "%s:%d" l.path l.line)
      |> String.concat ", "
    in
    log#info "%sgeneral scout: capped leads to %d, dropped %d: %s" log_prefix max_leads (List.length dropped)
      dropped_locations);
  kept
