(** General deep reviewer — second stage of the general review pipeline.

    Receives the scout's investigation leads and verifies each one against
    the diff and the contents of the files the leads point at.  Disprove-first
    posture: a lead only becomes a finding when the reviewer fails to refute
    it and can ground it in visible code.  Emits the same
    [Review_types.review_output] as the legacy single-pass review, so the
    downstream candidate filter and validator are unchanged. *)

let system_prompt =
  {|You are a deep code reviewer. A scout has flagged investigation leads in this
change. Your job is to verify each lead — not to re-review the whole diff.

## Method — for every lead, in order

1. Restate the lead's hypothesis in your own words.
2. Try to DISPROVE it: look for the guard, the caller contract, the test, the
   sibling update, or the invariant that makes the code correct despite the
   scout's suspicion. Most leads should die here.
3. Only if you cannot disprove it: establish the concrete failure — the input,
   state, or sequence that triggers it, and what goes observably wrong.
4. A confirmed lead becomes a finding with evidence copied verbatim from the
   provided code, anchored to the changed line responsible.

## Scope discipline

- Investigate every lead; do not skip any.
- Do not sweep the diff for new issues. If verifying a lead directly exposes a
  different defect in the same code you are reading (e.g. you check a guard and
  the guard itself is inverted), you may report it — nothing else.
- If the provided file contents are insufficient to confirm a lead, say so in
  the finding only when the risk is severe (critical severity with the missing
  context named in failure_scenario); otherwise drop the lead. Never guess.

## Findings

Only emit findings for defects with a concrete failure scenario. No style,
naming, documentation, praise, or "consider" comments — those are rejected
downstream and waste the lead's slot. severity: critical for likely breakage,
data loss, or corruption; warning for realistic failure paths; suggestion only
for a directly actionable correctness improvement. confidence reflects how
solid your verification evidence is.

## Output

A single JSON object matching the schema (summary, findings, overall
assessment). In `summary`, one line per lead: "L<n> <path>:<line> —
confirmed/refuted: <ten words>". `findings` contains only confirmed leads (and
any directly-observed defect per Scope discipline). Each finding's fields
follow the schema; `evidence_snippet` must be verbatim code from the provided
diff or file contents; `line` must be copied from the annotated diff's left
column or a file's numbered content, never estimated. No markdown fences, no
prose outside the JSON.|}

(* Sized for a single-shot batched verification with a private reasoning
   channel.  Independent of [General_review_plugin.general_review_thinking_budget]
   (the legacy single-pass path keeps its own copy); the two happen to share the
   value 4096 today but are tuned separately. *)
let deep_reviewer_thinking_budget = 4096

let config ~model_tier ~system_prompt_override : Agent_runner.agent_config =
  {
    name = "general_deep_review";
    system_prompt = CCOption.get_or ~default:system_prompt system_prompt_override;
    model_tier;
    output_schema = Review_types.review_output_jsonschema;
    max_steps = 1;
    thinking_budget = Some deep_reviewer_thinking_budget;
  }

let confidence_name = Review_types.confidence_to_string

(* Mirrors {!General_validator_agent.format_finding}: one numbered block per
   lead with labeled fields.  [index] drives the [L<n>] anchor the model must
   echo back in its per-lead summary lines. *)
let format_lead buf ~index (l : Review_types.scout_lead) =
  Printf.bprintf buf "### L%d\n\n" index;
  Printf.bprintf buf "**Location:** %s:%d\n" l.path l.line;
  (match l.end_line with
  | Some end_line -> Printf.bprintf buf "**End line:** %d\n" end_line
  | None -> ());
  Printf.bprintf buf "**Category:** %s\n" (Review_types.finding_category_to_string l.category);
  Printf.bprintf buf "**Confidence:** %s\n" (confidence_name l.confidence);
  Printf.bprintf buf "**Hypothesis:** %s\n" l.hypothesis;
  Buffer.add_char buf '\n'

(* File-section shape copied from {!Review_prompt.format_file_content}: the
   language fence is derived from the path extension and the contents are
   emitted verbatim (the legacy path performs no truncation).  The [### File:]
   header follows the deep-reviewer plan. *)
let format_file_content buf (path, content) =
  let ext =
    match String.rindex_opt path '.' with
    | Some i -> String.sub path (i + 1) (String.length path - i - 1)
    | None -> ""
  in
  Printf.bprintf buf "### File: %s\n```%s\n%s\n```\n" path ext content

(* Scout leads copy [path] verbatim from the annotated diff's git-style file
   headers ([diff --git a/… b/…], [--- a/…], [+++ b/…]), so a lead path may
   carry a single leading [a/] or [b/] segment.  Strip at most one such prefix
   so it lines up with the bare [file_contents] keys; a bare path is returned
   unchanged.  Only lead paths are normalized — [file_contents] keys are
   already bare repo-relative paths, and stripping them too would mangle a repo
   whose top-level directory is literally named [a] or [b]. *)
let normalize_lead_path path =
  match CCString.chop_prefix ~pre:"a/" path with
  | Some rest -> rest
  | None ->
  match CCString.chop_prefix ~pre:"b/" path with
  | Some rest -> rest
  | None -> path

(* Contents of ONLY the files a lead points at, in [file_contents] order, each
   path emitted once even when several leads (or duplicate [file_contents]
   entries) reference it.  Only the diff-derived lead paths are prefix-stripped
   (see {!normalize_lead_path}); the [file_contents] key is matched as-is, and
   the emitted section shows that actual key. *)
let relevant_file_contents ~leads ~file_contents =
  let lead_paths = List.map (fun (l : Review_types.scout_lead) -> normalize_lead_path l.path) leads in
  let referenced path = List.exists (String.equal path) lead_paths in
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (path, _content) ->
      match referenced path && not (Hashtbl.mem seen path) with
      | true ->
        Hashtbl.replace seen path ();
        true
      | false -> false)
    file_contents

let build_input ~leads ~diff_text ~change_title ~change_description ~file_contents () =
  let buf = Buffer.create (String.length diff_text + 1024) in
  Buffer.add_string buf "## Investigation Leads\n\n";
  List.iteri (fun i l -> format_lead buf ~index:i l) leads;
  Printf.bprintf buf "## Change: %s\n\n" change_title;
  (match String.length change_description > 0 with
  | true ->
    Buffer.add_string buf change_description;
    Buffer.add_string buf "\n\n"
  | false -> ());
  Buffer.add_string buf "## Relevant File Contents\n\n";
  List.iter (fun fc -> format_file_content buf fc) (relevant_file_contents ~leads ~file_contents);
  Buffer.add_char buf '\n';
  Buffer.add_string buf Review_prompt.annotated_diff_format_explainer;
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf
