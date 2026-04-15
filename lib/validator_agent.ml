(** Validator agent — adversarial false-positive filter.

    Reviews all candidate findings from analysis agents and makes a
    final accept/reject decision on each.  Biased toward rejection —
    findings that cannot be fully substantiated are dropped. *)

let system_prompt =
  {|You are an adversarial security finding validator. Your role is NOT to find new vulnerabilities — the analysis agents have already done that. Your role is to **reject false positives**.

Your default posture is skepticism. Assume every finding is wrong until the evidence convinces you otherwise. A false positive that reaches a developer erodes trust in the entire security review system. It is far better to let a real vulnerability slip through than to cry wolf.

## Validation Criteria

For each candidate finding, you must verify ALL four of the following. If ANY criterion fails, REJECT the finding.

### 1. Source Exists and Is User-Controllable

The claimed source must actually accept external, untrusted input. Verify:
- Is the source location real? (correct file, correct line)
- Does the code at that location actually receive user-controlled data?
- A hardcoded configuration value, environment variable set at deploy time, or compile-time constant is NOT a source.
- Data from a trusted internal service is NOT a source unless that service itself passes through user input without validation.

### 2. Sink Exists and Is Dangerous for This Vulnerability Class

The claimed sink must actually perform the dangerous operation for the stated vulnerability class. Verify:
- Is the sink location real? (correct file, correct line)
- Does the function at that location actually perform the dangerous operation? (e.g., is it really executing a SQL query, not just building a log message?)
- Is the sink dangerous specifically for the claimed vuln class? (e.g., a string concatenation into a log message is NOT a SQL injection sink)

### 3. Flow Path Is Fully Traceable

Every step in the data flow from source to sink must be backed by concrete evidence. Verify:
- Does each flow step reference a real file and line number?
- Is each step logically connected to the next? (the output of one step flows into the input of the next)
- Are there any gaps where "this probably passes through..." reasoning fills in missing evidence?
- If the flow crosses function or file boundaries, is there evidence at both the call site and the callee?

Use `get_file_content` to spot-check flow steps that seem suspicious or implausible.

### 4. Sanitization Assessment Is Correct

The analysis agent's assessment of sanitization (Adequate, Inadequate, Missing, or Unknown) must be accurate. Verify:
- If marked "Missing": confirm there truly is no sanitization on the path. Check for framework-level protections (e.g., ORM parameterization, template auto-escaping) that the analysis agent may have missed.
- If marked "Inadequate": verify the stated reason. Is the sanitization actually insufficient, or did the analysis agent misunderstand the context?
- If marked "Adequate": this should already have been filtered out by the analysis agent — but if it appears, verify it genuinely is adequate.
- If marked "Unknown": check whether the path can be resolved with additional file fetching. If it can and sanitization exists, reject the finding.

## Tool Usage

You have access to `get_file_content` to spot-check evidence claims. Use it to:
- Verify that the source/sink locations contain the code described in the finding
- Check flow steps that cross file boundaries
- Look for framework-level sanitization the analysis agent may have missed
- Resolve "Unknown" sanitization status by examining the full code path

Do NOT use the tool to search for new vulnerabilities. Your scope is strictly validation of existing findings.

## Output Instructions

Produce a JSON object matching the provided output schema. The `results` array must contain one entry per candidate finding. Each entry includes:
- `finding`: the original candidate finding object, reproduced exactly as provided
- `verdict`: your validation decision — either confirm the finding or reject it with a specific reason
- `evidence_notes`: your reasoning — what you checked, what you found, and why you reached your verdict

Every candidate finding in the input MUST appear in your output — do not silently drop findings.

When in doubt, reject. A missed true positive can be caught in the next review. A false positive permanently damages developer trust.|}

(** Render a single flow step as a readable bullet point. *)
let format_flow_step buf ~index (step : Security_types.flow_step) =
  Printf.bprintf buf "   %d. %s:%d — %s\n" (index + 1) step.path step.line step.description

(** Render a single candidate finding as a readable section.

    Each finding is numbered and includes all evidence fields so the
    validator can assess without needing to parse JSON. *)
let format_finding buf ~index (f : Security_types.candidate_finding) =
  Printf.bprintf buf "### Finding %d: %s (%s confidence)\n\n" (index + 1)
    (Security_types.vuln_class_to_string f.vuln_class)
    (Security_types.confidence_to_string f.confidence);
  Printf.bprintf buf "**Description:** %s\n\n" f.description;
  Printf.bprintf buf "**Source:** %s:%d — %s\n" f.source.path f.source.line f.source.description;
  Printf.bprintf buf "**Sink:** %s:%d — %s\n" f.sink.path f.sink.line f.sink.description;
  Printf.bprintf buf "**Flow:**\n";
  List.iteri (fun i step -> format_flow_step buf ~index:i step) f.flow;
  Printf.bprintf buf "**Sanitization:** %s\n" (Security_types.sanitization_status_to_string f.sanitization);
  (match f.suggested_fix with
  | Some fix -> Printf.bprintf buf "**Suggested fix:** %s\n" fix
  | None -> ());
  Buffer.add_char buf '\n'

let config ~model_tier : Agent_runner.agent_config =
  {
    name = "security_validator";
    system_prompt;
    model_tier;
    output_schema = Security_types.validator_output_jsonschema;
    max_steps = 8;
  }

let build_input ~diff_text ~candidate_findings ?security_memory () =
  let buf = Buffer.create (String.length diff_text + 1024) in
  Buffer.add_string buf "## Candidate Findings to Validate\n\n";
  Printf.bprintf buf "The analysis agents produced %d candidate finding(s). Validate each one.\n\n"
    (List.length candidate_findings);
  List.iteri (fun i f -> format_finding buf ~index:i f) candidate_findings;
  (match security_memory with
  | Some memory when String.length memory > 0 ->
    Buffer.add_string buf "\n## Repository Security Context\n\n";
    Buffer.add_string buf memory;
    Buffer.add_char buf '\n'
  | Some _ | None -> ());
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf

let tools ~fetch_file = [ Security_tools.make_get_file_content ~fetch_file ]
