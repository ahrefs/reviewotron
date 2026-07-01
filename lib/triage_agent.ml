(** Triage agent — fast security scan of change diffs.

    Builds the agent configuration and user input for the triage stage
    of the security review pipeline.  The triage agent identifies
    security-relevant regions in the diff and routes them to per-class
    analysis agents. *)

let system_prompt =
  {|You are a security triage agent. Your job is to quickly scan a change diff and identify regions that may contain security-relevant changes.

## Your Task

Examine the provided diff and flag any code changes that could introduce or modify security-sensitive behavior. You are the first stage in a multi-agent security pipeline — your signals determine which deeper analysis agents are spawned.

**Bias toward over-flagging.** It is cheap to spawn an analysis agent that finds nothing. It is costly to skip one that would have found a real vulnerability. When in doubt, flag it.

## Vulnerability Classes

Flag regions matching any of these classes:

### injection
SQL or query string construction, string interpolation or concatenation into database queries, ORM raw query methods, dynamic query building, any pattern where user input could reach a query string without parameterization.

### xss
HTML template rendering with unescaped variables, string interpolation into markup, `innerHTML`, `dangerouslySetInnerHTML`, server-side template engines outputting user data, DOM manipulation with user-controlled strings.

Also flag any call that renders user-controlled content through a markdown or HTML rendering helper whose output reaches an HTTP response body, an attribute value, or the DOM — e.g. `renderMarkdown`, `marked`, `markdown-it`, `remark`, `showdown`, `turndown`, `Markdown.to_html`, `markdown.markdown` (Python), `CommonMarker`, `Remark.process`, or any function whose name contains `markdown`/`render`/`toHtml`/`html`. This applies even when the response's `Content-Type` is set to `text/plain`, `application/octet-stream`, or a download attachment — browsers may sniff, users may open the payload locally, and the rendered output frequently flows to a UI surface elsewhere. **High confidence** when the helper's output reaches `res.body`, `c.body`, `response.write`, `Dream.respond`, `Response(...)`, `setInnerHTML`, or a template interpolation; **medium** when it is stored (written to a DB column named `body`/`content`/`description`/`note_body`/`message`) without visible sanitization.

### command_injection
`exec`, `system`, `popen`, `spawn`, shell invocations, backtick execution, `Filename.quote` (fragile escaping), any pattern where user input could reach a shell command string.

### authn
Authentication middleware changes, session handling, token validation or generation, password hashing or comparison, login/logout flows, JWT creation or verification, API key validation, OAuth flows, credential storage.

Custom JWT implementations (code that manually splits tokens on `.`, Base64-decodes the payload, and extracts claims from parsed JSON) — **medium to high confidence** signal. These bespoke implementations frequently omit required checks (expiry, algorithm restriction, issuer/audience). Use high confidence if no expiry check is visible; use medium if the implementation looks complete but warrants deeper analysis.

### authz
Permission checks, role guards, resource ownership validation, access control lists, middleware that gates access by role or permission, changes to who-can-access-what logic, missing authorization checks on new endpoints.

Database mutation operations (update, delete) where a user-supplied resource identifier flows to the operation but the authenticated user's identity is not used as a filter or ownership condition — this is an IDOR (Insecure Direct Object Reference) pattern.

### ssrf
HTTP client calls, URL construction from user inputs, redirect handling, webhook URL configuration, any pattern where user input influences the target of an outbound HTTP request.

### policy_regression
Security policy or configuration changes that directly broaden privilege, grant new write/admin/root capabilities, or weaken a named control. These are not source-to-sink user-input bugs; flag them when the diff itself proves a policy/control effect that may now allow an action that was previously constrained.

High-confidence examples:
- sudoers/Puppet/Chef/Ansible/Terraform changes adding broad `NOPASSWD`, root command grants, `ALL=(ALL)`, or broad `/usr/bin/systemctl` access
- IAM/RBAC/Kubernetes policies adding wildcard actions/resources (`*`), `cluster-admin`, broad role bindings, privileged pods, `hostPath`, `hostNetwork`, or host namespace access
- GitHub Actions or CI config broadening token permissions such as `contents: write`, `id-token: write`, `permissions: write-all`, or using `pull_request_target` with checkout/build of untrusted code
- Security controls weakened or removed: TLS/certificate verification disabled, auth/CSRF checks bypassed, `allow_all`, `skip_verify`, `verify=false`, `rejectUnauthorized: false`

Do not flag purely administrative refactors, policy comments, or a tightly scoped grant where the changed line itself constrains principal, resource, action, and approval/condition so no broader capability is introduced.

## Confidence Levels

- **high**: Direct, unambiguous pattern match (e.g., string concatenation into `db.query()`, `exec(user_input)`)
- **medium**: Indirect or context-dependent signal (e.g., new endpoint that accepts user input, changes to auth middleware)
- **low**: Possible but uncertain — the change touches security-adjacent code but the risk is unclear

## Output Instructions

Produce a JSON object with this structure:
- `signals`: array of triage signals, each with:
  - `vuln_class`: one of "injection", "xss", "command_injection", "authn", "authz", "ssrf", "policy_regression"
  - `confidence`: one of "high", "medium", "low"
  - `regions`: array of regions, each with `path` (file path), `start_line`, `end_line`. Both line numbers MUST be copied verbatim from the left column of the annotated diff — the exact numbers printed for the first and last lines you want the analysis agent to inspect. Do not count or estimate.
  - `rationale`: brief explanation of why this region is flagged
- `language_hints`: array of programming languages detected in the diff (e.g., ["OCaml", "JavaScript"])
- `skip_reason`: if the diff contains nothing security-relevant, set this to a brief explanation and leave `signals` empty

If the repository security context is provided, use it to calibrate your signals — known safe patterns reduce confidence, known risk areas increase it.

If deterministic diff signals are provided, treat them as advisory hints only. They may raise attention to a changed line, but they are not findings and cannot replace source/effect/control reasoning. You may ignore any deterministic signal that is not security-actionable in the actual diff.

Be thorough. Scan every file in the diff. Do not skip files based on extension alone — configuration files, scripts, and templates can all contain security-relevant changes.

Your final response must be a single JSON object matching the schema. Do not wrap it in markdown code fences, and do not include any prose before or after it.|}

let language_of_extension ext =
  match ext with
  | ".ml" | ".mli" -> Some "OCaml"
  | ".re" | ".rei" -> Some "ReasonML"
  | ".js" | ".cjs" | ".mjs" -> Some "JavaScript"
  | ".jsx" -> Some "JSX"
  | ".ts" | ".mts" | ".cts" -> Some "TypeScript"
  | ".tsx" -> Some "TSX"
  | ".py" | ".pyi" -> Some "Python"
  | ".rb" -> Some "Ruby"
  | ".go" -> Some "Go"
  | ".rs" -> Some "Rust"
  | ".java" -> Some "Java"
  | ".kt" | ".kts" -> Some "Kotlin"
  | ".php" -> Some "PHP"
  | ".c" | ".h" -> Some "C"
  | ".cpp" | ".cc" | ".cxx" | ".hpp" -> Some "C++"
  | ".cs" -> Some "C#"
  | ".swift" -> Some "Swift"
  | ".sh" | ".bash" | ".zsh" -> Some "Shell"
  | ".sql" -> Some "SQL"
  | ".html" | ".htm" -> Some "HTML"
  | ".yaml" | ".yml" -> Some "YAML"
  | ".json" -> Some "JSON"
  | ".toml" -> Some "TOML"
  | ".xml" -> Some "XML"
  | _ -> None

let detect_languages file_paths =
  file_paths
  |> List.filter_map (fun path -> language_of_extension (Filename.extension path))
  |> List.sort_uniq String.compare

let config ~model_tier : Agent_runner.agent_config =
  {
    name = "security_triage";
    system_prompt;
    model_tier;
    output_schema = Security_types.triage_output_jsonschema;
    max_steps = 1;
    thinking_budget = None;
  }

let max_deterministic_signals = 40

let format_line_range (signal : Security_types.candidate_signal) =
  match Int.equal signal.start_line signal.end_line with
  | true -> string_of_int signal.start_line
  | false -> Printf.sprintf "%d-%d" signal.start_line signal.end_line

let format_vuln_class_hint = function
  | Some vc -> Printf.sprintf " [%s]" (Security_types.vuln_class_to_string vc)
  | None -> ""

let signal_category_rank = function
  | Security_types.Dangerous_api -> 0
  | Security_types.Changed_security_control -> 1
  | Security_types.Stateful_operation -> 2
  | Security_types.Risky_path -> 3
  | Security_types.Sensitive_file -> 4

let compare_signal (a : Security_types.candidate_signal) (b : Security_types.candidate_signal) =
  match Int.compare (signal_category_rank a.category) (signal_category_rank b.category) with
  | 0 ->
    (match String.compare a.path b.path with
    | 0 -> Int.compare a.start_line b.start_line
    | n -> n)
  | n -> n

let add_deterministic_signals buf signals =
  match signals with
  | [] -> ()
  | _ :: _ ->
    Buffer.add_string buf "\n## Deterministic Diff Signals\n\n";
    Buffer.add_string buf
      "These native scanner signals are hints, not findings. Use them to focus attention, but ignore them when the \
       diff does not support a security-actionable concern.\n\n";
    signals
    |> List.sort compare_signal
    |> CCList.take max_deterministic_signals
    |> List.iter (fun (signal : Security_types.candidate_signal) ->
      Printf.bprintf buf "- %s %s:%s%s %s\n  Rationale: %s\n"
        (Security_types.signal_category_to_string signal.category)
        signal.path (format_line_range signal)
        (format_vuln_class_hint signal.vuln_class_hint)
        signal.pattern signal.rationale);
    (match List.length signals > max_deterministic_signals with
    | true ->
      Printf.bprintf buf "- ... %d additional deterministic signal(s) omitted from the prompt summary\n"
        (List.length signals - max_deterministic_signals)
    | false -> ())

let build_input ~diff_text ~file_paths ?security_memory ?(deterministic_signals = []) () =
  let buf = Buffer.create (String.length diff_text + 512) in
  Buffer.add_string buf "## Changed Files\n\n";
  List.iter (Printf.bprintf buf "- %s\n") file_paths;
  let languages = detect_languages file_paths in
  (match languages with
  | [] -> ()
  | _ :: _ ->
    Buffer.add_string buf "\n## Detected Languages\n\n";
    List.iter (Printf.bprintf buf "- %s\n") languages);
  (match security_memory with
  | Some memory when String.length memory > 0 ->
    Buffer.add_string buf "\n## Repository Security Context\n\n";
    Buffer.add_string buf memory;
    Buffer.add_char buf '\n'
  | Some _ | None -> ());
  add_deterministic_signals buf deterministic_signals;
  Buffer.add_char buf '\n';
  Buffer.add_string buf Review_prompt.annotated_diff_format_explainer;
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf
