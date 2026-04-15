(** Triage agent — fast security scan of PR diffs.

    Builds the agent configuration and user input for the triage stage
    of the security review pipeline.  The triage agent identifies
    security-relevant regions in the diff and routes them to per-class
    analysis agents. *)

let system_prompt =
  {|You are a security triage agent. Your job is to quickly scan a pull request diff and identify regions that may contain security-relevant changes.

## Your Task

Examine the provided diff and flag any code changes that could introduce or modify security-sensitive behavior. You are the first stage in a multi-agent security pipeline — your signals determine which deeper analysis agents are spawned.

**Bias toward over-flagging.** It is cheap to spawn an analysis agent that finds nothing. It is costly to skip one that would have found a real vulnerability. When in doubt, flag it.

## Vulnerability Classes

Flag regions matching any of these classes:

### injection
SQL or query string construction, string interpolation or concatenation into database queries, ORM raw query methods, dynamic query building, any pattern where user input could reach a query string without parameterization.

### xss
HTML template rendering with unescaped variables, string interpolation into markup, `innerHTML`, `dangerouslySetInnerHTML`, server-side template engines outputting user data, DOM manipulation with user-controlled strings.

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

## Confidence Levels

- **high**: Direct, unambiguous pattern match (e.g., string concatenation into `db.query()`, `exec(user_input)`)
- **medium**: Indirect or context-dependent signal (e.g., new endpoint that accepts user input, changes to auth middleware)
- **low**: Possible but uncertain — the change touches security-adjacent code but the risk is unclear

## Output Instructions

Produce a JSON object with this structure:
- `signals`: array of triage signals, each with:
  - `vuln_class`: one of "injection", "xss", "command_injection", "authn", "authz", "ssrf"
  - `confidence`: one of "high", "medium", "low"
  - `regions`: array of regions, each with `path` (file path), `start_line`, `end_line` (line numbers in the diff)
  - `rationale`: brief explanation of why this region is flagged
- `language_hints`: array of programming languages detected in the diff (e.g., ["OCaml", "JavaScript"])
- `skip_reason`: if the diff contains nothing security-relevant, set this to a brief explanation and leave `signals` empty

If the repository security context is provided, use it to calibrate your signals — known safe patterns reduce confidence, known risk areas increase it.

Be thorough. Scan every file in the diff. Do not skip files based on extension alone — configuration files, scripts, and templates can all contain security-relevant changes.|}

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
  }

let build_input ~diff_text ~file_paths ?security_memory () =
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
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf
