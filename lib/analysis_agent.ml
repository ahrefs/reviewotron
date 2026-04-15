(** Analysis agent — deep source-sink-flow-sanitization reasoning.

    Builds the agent configuration, user input, and tool set for
    per-vulnerability-class analysis agents.  Each analysis agent runs in
    parallel, using the shared 4-step methodology but with vulnerability-class
    and language-specific source/sink catalogs.

    Analysis agents use [get_file_content] for demand-driven context expansion
    when tracing data flows beyond the diff. *)

let shared_methodology =
  {|## Analysis Methodology

Follow these four steps in order. For each candidate vulnerability you identify, you must provide concrete evidence at every step.

### Step 1 — Source Identification

Find user-controlled inputs in the flagged regions. A source is any data that enters from outside the trust boundary:
- HTTP request parameters, headers, cookies, body fields
- URL path segments and query strings
- File uploads
- Database values that originated from user input
- Environment variables sourced from user-provided config
- Message queue payloads
- WebSocket messages

For each source, record the file path, line number, and a description of what data enters.

### Step 2 — Sink Identification

Find dangerous operations for the vulnerability class you are analyzing. A sink is any function or operation where tainted data could cause harm if it arrives unsanitized.

For each sink, record the file path, line number, and a description of what dangerous operation occurs.

### Step 3 — Data Flow Tracing

Trace whether each source can reach each sink. Follow the data through:
- Variable assignments and reassignments
- Function arguments and return values
- Object/record field access and mutation
- Collection operations (map, filter, fold)
- Async boundaries (callbacks, promises, Lwt binds)

If the flow path leaves the visible diff, use the `get_file_content` tool to fetch the relevant file and continue tracing. Record every step of the flow with file path, line number, and description.

**Critical**: Every step in the flow must be backed by evidence. No gaps, no assumptions, no "this probably passes through..." reasoning. If you cannot trace the full path, do not report the finding.

### Step 4 — Sanitization Evaluation

For each source→sink path you traced, evaluate whether adequate sanitization exists:
- **Adequate**: Context-correct sanitization is applied on every path from source to sink (e.g., parameterized queries for SQL, HTML encoding for XSS in HTML context, shell escaping for command injection)
- **Inadequate**: Sanitization exists but is insufficient — explain why (wrong encoding, wrong context, bypassable)
- **Missing**: No sanitization found on any path from source to sink
- **Unknown**: The path leaves the visible scope and you cannot determine sanitization status even after fetching additional files|}

let preamble =
  "You are a security analysis agent specializing in detecting vulnerabilities in code changes. You are part of a \
   multi-agent security pipeline — the triage stage has already identified this diff as potentially containing \
   security issues in your area of expertise.\n\n\
   Your task: perform deep analysis of the provided diff to find real, exploitable vulnerabilities.\n\n\
   **Precision is critical.** Only report findings where you can demonstrate the full source→sink→flow path with \
   concrete evidence. A false positive erodes developer trust. If you are unsure, do not report — it is better to miss \
   a finding than to report a false positive."

let tools_and_output_section =
  {|## Tools

You have access to `get_file_content` to fetch any file from the repository. Use it when:
- A data flow path leaves the visible diff (function defined in another file)
- You need to check a function's implementation to determine if it sanitizes input
- You need to verify framework configuration (e.g., template auto-escaping settings)

## Output Instructions

Produce a JSON object with:
- `findings`: array of candidate findings, each with full evidence chain (source, sink, flow steps, sanitization status, confidence, description, optional suggested_fix)
- `files_examined`: array of file paths you examined (from diff and via get_file_content)
- `notes`: any relevant observations about the codebase's security posture for this vuln class

If you find no vulnerabilities, return an empty `findings` array with a note explaining why the code is safe.|}

(** {2 Per-vulnerability-class prompt sections}

    Each constant provides class-specific source/sink catalogs and
    sanitization criteria.  The language hint note is appended
    by {!vuln_class_section} when language hints are present. *)

let injection_section =
  {|## Vulnerability Class: SQL/Query Injection

**Sources**: HTTP request parameters, form fields, URL path segments, query strings, headers, cookies — any user-controlled string that could be interpolated into a query.

**Sinks**: Database query functions that accept string arguments, raw SQL execution, ORM raw query methods, string concatenation or interpolation into query strings.

**Adequate sanitization**: Parameterized queries / prepared statements where user input is bound as a parameter (not interpolated into the query string). Type-safe query builders that prevent injection by construction.

**Inadequate sanitization**: Manual escaping, allowlist checks that can be bypassed, partial parameterization (some args parameterized, others interpolated).|}

let xss_section =
  {|## Vulnerability Class: Cross-Site Scripting (XSS)

**Sources**: HTTP request parameters, URL fragments, user-stored data rendered in templates, WebSocket messages displayed in UI.

**Sinks**: innerHTML assignments, dangerouslySetInnerHTML, server-side template rendering without escaping, DOM manipulation with user-controlled strings, document.write, eval with user strings.

**Adequate sanitization**: Context-correct output encoding (HTML entity encoding for HTML context, JavaScript escaping for JS context, URL encoding for URL context). Trusted template engines with auto-escaping enabled.

**Inadequate sanitization**: Encoding for wrong context (URL encoding in HTML context), allowlist that permits script-bearing tags, sanitization applied after insertion into DOM.|}

let command_injection_section =
  {|## Vulnerability Class: Command Injection

**Sources**: HTTP request parameters, file upload names, configuration values from user input, environment variables sourced from user-provided config.

**Sinks**: exec, system, popen, spawn, backtick execution, Process/ProcessBuilder calls, shell invocations, Filename.quote (fragile escaping).

**Adequate sanitization**: Avoiding shell invocation entirely (use array-form exec), strict allowlist of permitted values, language-native escaping functions used correctly.

**Inadequate sanitization**: Filename.quote (bypassable on some platforms), partial escaping, allowlist with overly broad patterns.|}

let authn_section =
  {|## Vulnerability Class: Authentication (AuthN)

**Sources**: Login credentials, session tokens, JWT tokens, API keys, OAuth tokens, password reset tokens — any authentication material.

**Sinks**: Token validation functions, password comparison, session creation/validation, JWT verification, credential storage.

**What to look for**:
- Missing or weak token validation (no expiry check, no signature verification)
- Hardcoded secrets or weak key generation
- Plaintext password storage or weak hashing (MD5, SHA1 without salt)
- Session fixation (no regeneration after authentication)
- Missing rate limiting on authentication endpoints
- Timing-safe comparison not used for token/password checks

**Adequate mitigation**: Strong hashing (bcrypt, argon2), proper JWT verification with expiry, secure session management, constant-time comparison.|}

let authz_section =
  {|## Vulnerability Class: Authorization (AuthZ)

**Sources**: User role/permission claims, resource identifiers in requests, path parameters identifying resources.

**Sinks**: Resource access functions, data retrieval by ID, administrative operations, permission-gated actions.

**What to look for**:
- Missing ownership checks (user A can access user B's resources via direct ID reference)
- Missing role/permission checks on new endpoints
- Inconsistent authorization between similar endpoints
- IDOR (Insecure Direct Object Reference) — resource accessed by ID without verifying the requester owns it
- Privilege escalation paths (regular user can reach admin functions)

**Adequate mitigation**: Ownership verification on every resource access, role-based access control consistently applied, authorization middleware on all protected routes.|}

let ssrf_section =
  {|## Vulnerability Class: Server-Side Request Forgery (SSRF)

**Sources**: URL parameters, webhook configuration URLs, redirect targets, any user-controlled string used to construct an outbound HTTP request.

**Sinks**: HTTP client calls (fetch, axios, curl, http.get, Cohttp, Piaf), URL construction for outbound requests, redirect responses.

**What to look for**:
- User-controlled URLs passed directly to HTTP clients
- URL construction via string concatenation with user input
- Open redirects that could be chained with SSRF
- Missing URL validation / allowlist for outbound requests
- DNS rebinding potential (validation at resolution time, request at different time)

**Adequate mitigation**: URL allowlist with domain and protocol validation, blocking internal/private IP ranges, using a proxy with egress filtering.

**Inadequate mitigation**: Blocklist of known-bad IPs (bypassable via DNS rebinding, IPv6, or alternate encodings), validation of URL string without resolving.|}

let vuln_class_section vuln_class ~language_hints =
  let language_note =
    match language_hints with
    | [] -> ""
    | _ :: _ ->
      Printf.sprintf
        "\n\nLanguages detected in this diff: %s. Focus your analysis on patterns specific to these languages."
        (String.concat ", " language_hints)
  in
  let base =
    match vuln_class with
    | Security_types.Injection -> injection_section
    | Security_types.Xss -> xss_section
    | Security_types.Command_injection -> command_injection_section
    | Security_types.Authn -> authn_section
    | Security_types.Authz -> authz_section
    | Security_types.Ssrf -> ssrf_section
  in
  base ^ language_note

let build_system_prompt ~vuln_class ~language_hints =
  String.concat "\n\n"
    [ preamble; shared_methodology; vuln_class_section vuln_class ~language_hints; tools_and_output_section ]

let config ~vuln_class ~model_tier ~language_hints : Agent_runner.agent_config =
  let name = Printf.sprintf "security_analysis_%s" (Security_types.vuln_class_to_string vuln_class) in
  let system_prompt = build_system_prompt ~vuln_class ~language_hints in
  { name; system_prompt; model_tier; output_schema = Security_types.analysis_output_jsonschema; max_steps = 10 }

let append_regions buf regions =
  List.iter
    (fun (r : Security_types.region) -> Printf.bprintf buf "  - %s lines %d-%d\n" r.path r.start_line r.end_line)
    regions

let build_input ~diff_text ~triage_signals ~file_paths ?security_memory () =
  let buf = Buffer.create (String.length diff_text + 512) in
  Buffer.add_string buf "## Triage Signals\n\n";
  Buffer.add_string buf "The triage agent flagged the following regions for your analysis:\n\n";
  List.iter
    (fun (s : Security_types.triage_signal) ->
      Printf.bprintf buf "### %s (confidence: %s)\n"
        (Security_types.vuln_class_to_string s.vuln_class)
        (Security_types.confidence_to_string s.confidence);
      Printf.bprintf buf "Rationale: %s\n" s.rationale;
      Buffer.add_string buf "Regions:\n";
      append_regions buf s.regions;
      Buffer.add_char buf '\n')
    triage_signals;
  Buffer.add_string buf "## Changed Files\n\n";
  List.iter (Printf.bprintf buf "- %s\n") file_paths;
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
