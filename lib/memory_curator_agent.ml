let system_prompt =
  {|You are the Security Memory Curator for a code review tool. Your job is to maintain a short architectural brief for a specific repository so that future security reviews have the minimum context they need to triage a diff accurately.

## What the brief is for

The brief is injected into the triage agent's prompt on every future review. Triage reads it to decide which parts of a diff to escalate. The brief must therefore describe the repository's shape — not catalogue past findings.

## Memory format

The brief is a markdown document with exactly two sections:

### Architecture
Stable facts about the repository that are expensive to rederive from a single diff: primary language(s) and framework, persistence layer, authentication/authorization approach, templating/rendering approach, and any notable project-wide conventions.

### Known Safe Patterns
Recurring wrappers or helpers the repository uses that are known-safe when invoked correctly (e.g. a query builder with prepared statements, an HTML-escaping helper). Each entry should name the pattern and, when useful, how to recognise correct usage. No file:line references.

## Hard rules

1. Do NOT record specific line numbers, path:line references, or per-finding details. The brief describes patterns, not instances.
2. Do NOT create any section other than "## Architecture" and "## Known Safe Patterns". In particular, do not introduce a "Known Risk Areas", "Confirmed findings", "Suppressions", or "Incidents" section.
3. Do NOT invent information. Only integrate what the architectural observations in the input directly support, plus what the current brief (if any) already contains.
4. Stay within the configured token budget. If the document would exceed it, compress by merging related bullets and dropping low-signal detail — never by adding more sections.
5. Preserve the level-1 heading with the repository name.
6. Each entry is a single concise bullet; no multi-paragraph prose.

## Output

Produce a JSON object with a single field:
- `updated_memory`: the complete updated markdown document as a string.

Your final response must be a single JSON object matching the schema. Do not wrap it in markdown code fences, and do not include any prose before or after it.|}

let config ~model_tier : Agent_runner.agent_config =
  {
    name = "memory_curator";
    system_prompt;
    model_tier;
    output_schema = Security_types.curator_output_jsonschema;
    max_steps = 1;
    thinking_budget = None;
  }

let estimate_tokens s = (String.length s + 3) / 4

let format_distribution buf distribution =
  match distribution with
  | [] -> ()
  | _ :: _ ->
    Buffer.add_string buf "\n## Triage Vuln-Class Distribution (past review)\n\n";
    List.iter (fun (vc, n) -> Printf.bprintf buf "- %s: %d signal(s)\n" vc n) distribution

let format_reviewed_files buf files =
  match files with
  | [] -> ()
  | _ :: _ ->
    let sample =
      match List.compare_length_with files 12 > 0 with
      | true -> CCList.take 12 files @ [ "..." ]
      | false -> files
    in
    Buffer.add_string buf "\n## Reviewed Files (past review, sampled)\n\n";
    List.iter (Printf.bprintf buf "- %s\n") sample

let format_language_hints buf hints =
  match hints with
  | [] -> ()
  | _ :: _ ->
    Buffer.add_string buf "\n## Language Hints (past review)\n\n";
    List.iter (Printf.bprintf buf "- %s\n") hints

let build_input ~repo_name ~memory_max_tokens ~(observations : Security_types.architectural_observations)
  ?current_memory () =
  let buf = Buffer.create 1024 in
  Printf.bprintf buf "## Repository\n\n%s\n" repo_name;
  (match current_memory with
  | Some memory when String.length memory > 0 ->
    Buffer.add_string buf "\n## Current Brief\n\n";
    Buffer.add_string buf memory;
    Buffer.add_char buf '\n';
    Printf.bprintf buf "\n## Token Budget\n\nCurrent: ~%d tokens\nMaximum: %d tokens\n" (estimate_tokens memory)
      memory_max_tokens
  | Some _ | None ->
    Buffer.add_string buf "\n## Current Brief\n\nNo existing brief.\n";
    Printf.bprintf buf "\n## Token Budget\n\nCurrent: 0 tokens\nMaximum: %d tokens\n" memory_max_tokens);
  format_language_hints buf observations.language_hints;
  format_reviewed_files buf observations.reviewed_files;
  format_distribution buf observations.vuln_class_distribution;
  Buffer.contents buf
