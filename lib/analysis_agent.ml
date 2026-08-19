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

For `policy_regression`, do not look for a runtime user-controlled source. The source is the changed principal, grant,
configuration entry, or removed/disabled control. Record the exact changed file and line that creates the broader policy
state.

### Step 2 — Sink Identification

Find dangerous operations for the vulnerability class you are analyzing. A sink is any function or operation where tainted data could cause harm if it arrives unsanitized.

For each sink, record the file path, line number, and a description of what dangerous operation occurs.

For `policy_regression`, the sink is the effective privileged capability or weakened security boundary made possible by
the changed policy/control, such as "deploy user can run systemctl as root without a password", "workflow token can write
repository contents from this job", "service account now has wildcard Kubernetes verbs", or "TLS certificate validation
is disabled for outbound requests".

**Render the sink's actual input.** Before claiming a sink is reached unsafely, quote the exact argument expression from the source (verbatim — including template literals, array element positions, wrapping helper calls, and any string construction that happens at the call site). Then state, in plain prose, the concrete string the sink receives at runtime. Do not paraphrase, do not abstract, and do not skip this step.

Example — if the code is:
```
await runPipeline([
  { cmd: "openssl", args: ["enc", "-pass", `pass:${opts.passphrase}`, "-out", encPath] },
]);
```
and `runPipeline` applies `shellQuote` to each `args` element, then before reasoning about injection you must note:
- `args[2]` is the single JS string `"pass:" + opts.passphrase` (template-literal concatenation happens BEFORE the array is passed).
- `shellQuote` receives that single string as one argument and wraps the whole thing in double quotes.
- The string the shell sees is literally `"pass:<passphrase contents>"`, with `pass:` inside the quoted token, not outside it.

Only after writing down what the sink actually receives should you reason about whether the escaping is adequate. Models frequently mis-model JS template literals as if the prefix were outside the quoted token — writing the input out explicitly prevents that class of false positive.

### Step 3 — Data Flow Tracing

Trace whether each source can reach each sink. Follow the data through:
- Variable assignments and reassignments
- Function arguments and return values
- Object/record field access and mutation
- Collection operations (map, filter, fold)
- Async boundaries (callbacks, promises, Lwt binds)

If the flow path leaves the visible diff, use the `get_file_content` tool to fetch the relevant file and continue tracing. Record every step of the flow with file path, line number, and description.

**Critical**: Every step in the flow must be backed by evidence. No gaps, no assumptions, no "this probably passes through..." reasoning. If you cannot trace the full path, do not report the finding.

For `policy_regression`, trace policy effect rather than data flow: changed line -> effective policy/control state ->
concrete action or boundary bypass now possible. The trace may live entirely in the diff when the policy language is
self-contained, but every step still needs exact file and line evidence.

### Step 4 — Sanitization Evaluation

For each source→sink path you traced, evaluate whether adequate sanitization exists:
- **Adequate**: Context-correct sanitization is applied on every path from source to sink (e.g., parameterized queries for SQL, HTML encoding for XSS in HTML context, shell escaping for command injection)
- **Inadequate**: Sanitization exists but is insufficient — explain why (wrong encoding, wrong context, bypassable)
- **Missing**: No sanitization found on any path from source to sink
- **Unknown**: The path leaves the visible scope and you cannot determine sanitization status even after fetching additional files

For `policy_regression`, treat sanitization as the scoping/mitigation on the grant or weakened control:
- **Adequate**: principal, action, resource, environment, approval/condition, tenant/user boundary, or compensating control
  is narrow enough that no broader capability is introduced
- **Inadequate**: a mitigation exists but is too broad or bypassable
- **Missing**: no meaningful scoping, allowlist, approval, condition, boundary, or compensating control is present
- **Unknown**: the effective scope cannot be established even after fetching needed context|}

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

### Fetch Economy

Fetch a file only when you cannot assess a concrete hypothesis from the diff and already-fetched context. Do not fetch
speculatively. Prefer a supported conclusion, including no finding, over gathering more context.

### Fetched File Format

Files returned by `get_file_content` are presented with the same left-column line-number gutter as the annotated diff, prefixed by a `# File: <path>` header. Example:

```
# File: src/middleware/session.ts
   1 |  import { sign, verify } from "hono/jwt";
   2 |  import type { MiddlewareHandler } from "hono";
   3 |
  24 |    const payload = (await verifyToken(raw)) ?? decodePayload(raw);
```

- The path on the `# File:` header is the authoritative path of every line that follows, up to the next `# File:` header. Never attribute a line to a neighboring file or a file that was merely mentioned in prose.
- Use the numbers in the left column verbatim as `line` values — do not count, do not estimate.

## Output Instructions

Produce a JSON object with:
- `findings`: array of candidate findings, each with full evidence chain (source, sink, flow steps, sanitization status, confidence, description, optional suggested_fix)
- `files_examined`: array of file paths you examined (from diff and via get_file_content)
- `notes`: any relevant observations about the codebase's security posture for this vuln class

Every `line` value in any finding, source, sink, or flow step MUST be copied verbatim from the left column of the annotated diff or a fetched file. Do not count lines, do not estimate, and do not use tilde (`~`) or approximate notations in messages — the column gives you the exact number.

The `path` field on every finding, source, sink, and flow step MUST be the exact path of the file where that code actually lives — copied verbatim from either the `+++ b/` header in the annotated diff, or the `# File:` header of a fetched file. You know which code belongs to which file because every line you read is presented under a file header. Do NOT:
- substitute a neighboring file (e.g., put `requireAdmin.ts` when the code is in `session.ts`),
- use a caller or consumer file as the sink location (the sink lives where the dangerous operation is written, not where it is invoked),
- invent paths that you did not see in a diff header or tool response.

If a vulnerability's sink is in unchanged code that this change reaches into, set `sink.path` and `sink.line` to the unchanged file's exact path and line — the reviewer routes such findings into a dedicated section of the main review body. This is preferred over mis-attributing to a changed file.

The `sanitization` field must be one of the strings `"adequate"`, `"inadequate"`, `"missing"`, or `"unknown"`. When it is `"inadequate"` or `"unknown"`, explain the reason in the finding's `description` field — do not attach it to the `sanitization` value itself.

Your final response must be a single JSON object matching the schema. Do not wrap it in markdown code fences, and do not include any prose before or after it.

If you find no vulnerabilities, return an empty `findings` array with a note explaining why the code is safe.|}

(** {2 Per-vulnerability-class prompt sections}

    Each constant provides class-specific source/sink catalogs and
    sanitization criteria.  The language hint note is appended
    by {!vuln_class_section} when language hints are present. *)

let injection_section =
  {|## Vulnerability Class: SQL/Query Injection

This class covers all injection types where user-controlled data reaches a query interpreter: SQL injection, NoSQL injection, and ORM query injection. Also watch for second-order injection where user input stored in a database is later retrieved and used unsafely in a query.

### Sources (User-Controlled Input)

**OCaml / Dream:**
- `Dream.query` — URL query parameters
- `Dream.param` — route path parameters
- `Dream.body` / `Dream.form` — POST body and form fields
- `Dream.header` / `Dream.cookie` — HTTP headers and cookies

**JavaScript / Express:**
- `req.params` — route parameters
- `req.query` — URL query string
- `req.body` — parsed request body
- `req.headers` / `req.cookies` — HTTP headers and cookies
- `req.get()` — header accessor

**Python / Django / Flask:**
- `request.GET` / `request.POST` — Django query and form data
- `request.data` / `request.query_params` — Django REST Framework
- `request.args` / `request.form` / `request.json` — Flask
- `request.headers` / `request.cookies` — both frameworks

### Sinks (Dangerous Operations)

**SQL Injection:**
- **OCaml**: String concatenation or interpolation into `Caqti_request.exec`, `Caqti_request.find`, `Caqti_request.collect`; any `Printf.sprintf` or `^` building a SQL string passed to a database function; `Petrol` raw query construction
- **JavaScript**: `connection.query("SELECT ... " + input)`, `sequelize.query(raw_string)`, `knex.raw(user_string)`, template literal SQL with `${user_input}`, `pg` client `query` with string concat
- **Python**: `cursor.execute("SELECT ... " + input)`, `cursor.execute("SELECT ... %s" % input)`, `cursor.execute(f"SELECT ... {input}")`, `django.db.connection.cursor()` with string formatting, `SQLAlchemy text()` with string interpolation, `engine.execute(raw_string)`

**NoSQL Injection:**
- **JavaScript**: `collection.find({field: user_input})` where `user_input` is a parsed object (e.g., `req.body` containing `{"$gt": ""}`) — MongoDB operator injection
- **Python**: `pymongo collection.find(user_dict)`, `collection.aggregate(user_pipeline)` — MongoDB operator injection via user-constructed query objects
- **Any language**: User input used as keys or operators in query objects without validation

**ORM Query Injection:**
- **Python**: `Model.objects.raw(user_string)`, `Model.objects.extra(where=[user_string])`, `RawSQL(user_string)`
- **JavaScript**: `sequelize.literal(user_string)`, `Sequelize.where(Sequelize.literal(user_string))`

### Sanitization Assessment

**Adequate — these patterns prevent injection by construction:**
- OCaml: Caqti type-safe request API using `Caqti_type` parameter binding (e.g., `Caqti_request.find Caqti_type.int Caqti_type.string "SELECT name FROM users WHERE id = ?"`)
- JavaScript: Parameterized queries with `?` placeholders (e.g., `connection.query("SELECT ... WHERE id = ?", [input])`), ORM model methods with object conditions
- Python: Parameterized queries with `%s` placeholder and tuple (e.g., `cursor.execute("SELECT ... WHERE id = %s", (input,))`), Django ORM queryset methods (`filter`, `exclude`, `get`, `annotate`), SQLAlchemy bound parameters via `bindparam` or `:name` syntax
- Any language: Prepared statements where user input is bound as a parameter, never interpolated into the query string

**Inadequate — these attempts at sanitization are insufficient:**
- Manual string escaping (can miss edge cases, database-dialect-specific)
- Escaping for the wrong database dialect (MySQL escaping used with PostgreSQL)
- Partial parameterization (some arguments parameterized, others interpolated in the same query)
- Allowlist checks on the value but not the structure (e.g., checking value is alphanumeric but allowing it to set the column name)
- `parseInt` / `int()` type casting applied inconsistently across all paths

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble injection but are not exploitable:
- Caqti requests using type-safe parameter binding (even if the SQL string is built with `^`, the parameters are bound safely)
- Django ORM calls like `filter()`, `exclude()`, `values()`, `annotate()` — these are parameterized by the framework
- Sequelize/Knex model methods with object-form conditions (e.g., `Model.findOne({ where: { id: input } })`)
- String concatenation used to build log messages, error messages, or debug output — not query strings
- SQL table or column names from hardcoded constants, even if assembled via string concatenation
- Query construction where ALL user-controlled values go through parameter binding, even if static query structure uses concatenation|}

let xss_section =
  {|## Vulnerability Class: Cross-Site Scripting (XSS)

This class covers reflected XSS (user input immediately rendered back in a response), stored XSS (user input persisted and later rendered to other users), and DOM-based XSS (client-side JavaScript reads a user-controlled DOM source and writes it to a dangerous sink without server involvement).

### Sources (User-Controlled Input)

**Server-Side Sources (reflected and stored XSS):**

**OCaml / Dream:**
- `Dream.query` — URL query parameters
- `Dream.param` — route path parameters
- `Dream.body` / `Dream.form` — POST body and form fields
- `Dream.header` / `Dream.cookie` — HTTP headers and cookies
- Database-retrieved user content rendered in HTML responses

**JavaScript / Express:**
- `req.params` — route parameters
- `req.query` — URL query string
- `req.body` — parsed request body
- `req.headers` / `req.cookies` — HTTP headers and cookies
- Database-retrieved user content rendered in templates or sent as HTML

**Python / Django / Flask:**
- `request.GET` / `request.POST` — Django query and form data
- `request.data` / `request.query_params` — Django REST Framework
- `request.args` / `request.form` / `request.json` — Flask
- `request.headers` / `request.cookies` — both frameworks
- Model fields containing user-generated content rendered in templates

**Client-Side Sources (DOM-based XSS):**
- `window.location` / `document.URL` / `document.documentURI` — full URL
- `location.hash` / `location.search` / `location.href` — URL fragments and query strings
- `document.referrer` — referrer header accessible in JS
- `window.name` — cross-origin writable
- `postMessage` event data (`event.data`) — messages from other windows/iframes
- `document.cookie` — if set by attacker-controlled subdomain
- Web Storage (`localStorage` / `sessionStorage`) — if populated from untrusted source

### Sinks (Dangerous Operations)

**Server-Side Template Rendering:**
- **OCaml / Dream**: `Dream.html` with string concatenation or `Printf.sprintf` containing user data; raw string responses with `Content-Type: text/html`; `Tyxml.Html.Unsafe.data` or any raw HTML injection bypassing Tyxml's type safety
- **Python / Django**: `mark_safe(user_input)`, `|safe` template filter on user data, `{% autoescape off %}` blocks containing user data, `HttpResponse(user_html)` with unescaped content
- **Python / Flask / Jinja2**: `render_template_string(user_input)`, `Markup(user_input)`, `|safe` filter, `Environment(autoescape=False)` with user data in templates
- **JavaScript / Express**: Template engines with unescaped output — EJS `<%- user_input %>`, Pug `!{user_input}`, Handlebars `{{{user_input}}}`

**Client-Side DOM Manipulation:**
- `element.innerHTML` / `element.outerHTML` — HTML parsing of assigned string
- `element.insertAdjacentHTML()` — inserts HTML at specified position
- `document.write()` / `document.writeln()` — writes HTML to document stream
- `DOMParser.parseFromString()` followed by insertion into live DOM

**Client-Side JavaScript Execution:**
- `eval(user_string)` — direct code execution
- `setTimeout(user_string, ...)` / `setInterval(user_string, ...)` — string form executes as code
- `new Function(user_string)` — dynamic function creation
- `javascript:` URI scheme in `href` or `src` attributes with user data

**Framework-Specific Dangerous APIs:**
- **React**: `dangerouslySetInnerHTML={{ __html: user_input }}`
- **Vue**: `v-html="user_input"`
- **Angular**: `[innerHTML]="user_input"`, `bypassSecurityTrustHtml(user_input)`
- **Svelte**: `{@html user_input}`
- **jQuery**: `.html(user_input)`, `.append(user_html_string)`, `$(user_selector)`

### Sanitization Assessment

**Adequate — these patterns prevent XSS by construction:**
- Context-correct output encoding: HTML entity encoding (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&#x27;`) for HTML body context; JavaScript string escaping for inline JS context; URL encoding for URL parameter context
- DOMPurify: `DOMPurify.sanitize(user_input)` with default configuration strips dangerous elements and attributes
- Framework auto-escaping: React JSX expressions `{variable}` are auto-escaped; Django templates `{{ variable }}` auto-escape by default; Jinja2 with `autoescape=True`; OCaml Tyxml typed HTML construction (type system prevents raw HTML injection)
- Server-side HTML sanitization libraries with allowlist approach (e.g., `nh3.clean()` or `bleach.clean()` in Python, `sanitize-html` in Node.js) when configured with a restrictive tag/attribute allowlist
- Content Security Policy (CSP): a restrictive `script-src` directive (e.g., `script-src 'self'` without `'unsafe-inline'`) provides defense-in-depth by preventing inline script execution even if an XSS payload reaches the DOM. CSP alone is not sufficient mitigation — output encoding is still required — but its presence significantly reduces exploitability

**Inadequate — these attempts at sanitization are insufficient:**
- Encoding for wrong context (HTML entity encoding inside a JavaScript string literal, or inside a CSS `url()` value)
- Blocklist-based filtering: removing `<script>` tags but not `<img onerror=...>`, `<svg onload=...>`, or other event handler vectors
- Regex-based HTML stripping (cannot reliably parse HTML; bypasses via encoding, comments, or malformed tags)
- Client-side-only validation/sanitization (attacker can bypass by sending requests directly)
- `strip_tags()` / equivalent — misses attribute-based XSS vectors (`<div onmouseover=...>`)
- Truncation or length limits as the sole defense (payloads can be short)
- `encodeURIComponent` used as the sole defense for HTML context (produces percent-encoding, not HTML entities; does not protect in unquoted attributes or event handler contexts)

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble XSS but are not exploitable:
- React JSX expressions `{variable}` — React auto-escapes all interpolated values by default; only `dangerouslySetInnerHTML` bypasses this
- Django template `{{ variable }}` — auto-escaped by default; only `|safe` filter or `{% autoescape off %}` disables escaping
- Jinja2 templates with `autoescape=True` (the default in Flask) — `{{ variable }}` is auto-escaped
- OCaml Tyxml typed HTML — the type system prevents injecting raw strings into HTML nodes; only `Unsafe.data` bypasses this
- Content rendered as JSON API responses (`Content-Type: application/json`) — not interpreted as HTML by browsers
- Plain text responses (`Content-Type: text/plain`) — browsers do not parse HTML in plain text
- Static HTML strings with no user-controlled input (hardcoded markup)
- `innerHTML` or `.html()` assigned from hardcoded constants, trusted configuration, or server-rendered content with no user input in the path
- Escaped template output used in HTML attributes that are properly quoted (e.g., `<div title="{{ escaped_value }}">`)
- User input used only in `textContent` / `innerText` assignments — these do not parse HTML|}

let command_injection_section =
  {|## Vulnerability Class: Command Injection

This class covers OS command injection where user-controlled data reaches a system shell or process execution function. The key distinction is between **shell-mediated execution** (where shell metacharacters like `;`, `|`, `&&`, `$()`, and backticks are interpreted by a shell) and **direct process execution** (where arguments are passed directly to `execve` without shell interpretation). Shell-mediated execution is far more dangerous because a single injected metacharacter can chain arbitrary commands.

### Sources (User-Controlled Input)

**OCaml / Dream:**
- `Dream.query` — URL query parameters
- `Dream.param` — route path parameters
- `Dream.body` / `Dream.form` — POST body and form fields
- `Dream.header` / `Dream.cookie` — HTTP headers and cookies
- `Dream.upload` — uploaded file names (often used in file-processing commands)

**JavaScript / Express:**
- `req.params` — route parameters
- `req.query` — URL query string
- `req.body` — parsed request body
- `req.headers` / `req.cookies` — HTTP headers and cookies
- `req.file.originalname` / `req.files` — uploaded file names (multer, formidable)

**Python / Django / Flask:**
- `request.GET` / `request.POST` — Django query and form data
- `request.data` / `request.query_params` — Django REST Framework
- `request.args` / `request.form` / `request.json` — Flask
- `request.headers` / `request.cookies` — both frameworks
- `request.FILES` (Django) / `request.files` (Flask) — uploaded file names

**Cross-language sources:**
- Database-stored values later used in shell commands (second-order injection)
- User-provided file paths or directory names passed to command-line tools
- Environment variables sourced from user-editable configuration files
- Message queue payloads, webhook bodies, or other inter-service inputs

### Sinks (Dangerous Operations)

**Shell-Mediated Execution (metacharacters interpreted — highest risk):**

- **OCaml**: `Sys.command cmd` — passes `cmd` to `/bin/sh -c`; `Unix.open_process_in`, `Unix.open_process_out`, `Unix.open_process`, `Unix.open_process_full` — all invoke `/bin/sh -c` on the command string; `Lwt_process.shell cmd` — constructs a shell command for Lwt process functions; `Lwt_process.exec`, `Lwt_process.open_process_in` — Lwt-wrapped process execution (shell-mediated when using `Lwt_process.shell`)
- **JavaScript**: `child_process.exec(cmd)` / `child_process.execSync(cmd)` — invokes shell; `child_process.spawn(cmd, args, { shell: true })` or `child_process.execFile(cmd, args, { shell: true })` — shell flag enables metacharacter interpretation
- **Python**: `os.system(cmd)`, `os.popen(cmd)` — invoke shell; `subprocess.Popen(cmd, shell=True)`, `subprocess.call(cmd, shell=True)`, `subprocess.run(cmd, shell=True)`, `subprocess.check_call(cmd, shell=True)`, `subprocess.check_output(cmd, shell=True)` — `shell=True` enables shell interpretation; `commands.getoutput(cmd)` / `commands.getstatusoutput(cmd)` (legacy, Python 2)

**Direct Process Execution (no shell, but program path or arguments may be user-controlled):**

- **OCaml**: `Unix.create_process prog args` — no shell, but dangerous if `prog` is user-controlled; `Unix.execvp prog args` / `Unix.execve prog args env` — replaces current process with `prog`
- **JavaScript**: `child_process.spawn(prog, args)` (without `shell: true`), `child_process.execFile(prog, args)` (without `shell: true`) — no shell, but dangerous if `prog` is user-controlled or if `args` contain values that the target program interprets as flags/options (argument injection)
- **Python**: `subprocess.Popen([prog, arg1, arg2])`, `subprocess.run([prog, ...])`, `subprocess.call([prog, ...])`, `subprocess.check_call([prog, ...])`, `subprocess.check_output([prog, ...])` (all without `shell=True`) — no shell, but dangerous if `prog` is user-controlled; also vulnerable to argument injection if user controls arguments to programs that interpret them dangerously (e.g., `curl`, `rsync`, `tar`, `git`)

**Argument injection (special case):**
Even with array-form execution, user-controlled arguments to certain programs can be dangerous. For example, `git` accepts `--upload-pack` which can execute arbitrary commands, `tar` accepts `--checkpoint-action=exec=CMD`, and `curl` accepts `-o` to write files. Report these when user input flows into arguments of such programs.

### Sanitization Assessment

**Adequate — these patterns prevent command injection:**
- Array-form / list-form process execution without shell invocation (e.g., `subprocess.run([prog, arg1, arg2])`, `child_process.spawn(prog, [arg1, arg2])`, `Unix.create_process prog [|prog; arg1; arg2|]`) — shell metacharacters are not interpreted
- `shlex.quote(user_input)` in Python on Unix — correctly wraps input in single quotes with internal single-quote escaping for use in shell command strings
- `Filename.quote` in OCaml on Unix — wraps in single quotes with correct escaping; safe for passing a single argument to a POSIX shell
- Strict allowlist validation: user input is compared against a fixed set of known-safe values (e.g., selecting a format from `["pdf", "csv", "json"]`) before use in a command
- Avoiding shell entirely by using library APIs instead of command-line tools (e.g., using a PDF library instead of shelling out to `wkhtmltopdf`)
- `--` argument separator before user-controlled arguments to prevent flag injection (e.g., `["git", "checkout", "--", user_branch]`)

**Inadequate — these attempts at sanitization are insufficient:**
- Blocklist of shell metacharacters (e.g., filtering `;`, `|`, `&`) — incomplete, misses `$()`, backticks, newlines, or encoding bypasses
- Custom regex-based escaping or character stripping — fragile, easy to miss edge cases
- `Filename.quote` on Windows — the Win32 implementation uses double-quote escaping which does not protect against all `cmd.exe` metacharacters (`%VAR%` expansion, `^` escaping, `!` in delayed expansion contexts); Windows command-line quoting is fundamentally more complex than POSIX shell quoting
- `shlex.quote` combined with `shell=True` and complex pipelines — quoting protects a single argument, but if the overall command template has structural injection points, quoting one part may not help
- URL-encoding, HTML-encoding, or other context-incorrect encoding applied to shell arguments
- Truncation or length limits as the sole defense (command injection payloads can be very short: `; id`)
- Checking for path traversal (`../`) without checking for shell metacharacters — these are orthogonal concerns

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble command injection but are not exploitable:
- Array-form / list-form exec with hardcoded program and no shell invocation, where the target program has no dangerous flag-based execution: `subprocess.run(["cat", user_file])`, `child_process.spawn("echo", [user_input])`, `Unix.create_process "/usr/bin/wc" [|"wc"; "-l"; user_file|]` — no shell metacharacter interpretation occurs
- Hardcoded shell commands with no user-controlled input: `Sys.command "make clean"`, `os.system("systemctl restart nginx")` — no injection vector
- Commands where user input selects from a hardcoded enum or allowlist validated before use in the command (e.g., `match format with "pdf" | "csv" -> ... ` followed by use in a command)
- `Sys.command` or `os.system` used only in build scripts, test fixtures, or development tooling — not reachable from user input in production
- String concatenation building log messages, error messages, or debug output that happens to mention command names — not passed to an execution function
- `Unix.create_process` / `Unix.execvp` with user input only in arguments (not the program path) where the target program does not support dangerous flag-based execution|}

let authn_section =
  {|## Vulnerability Class: Authentication (AuthN)

This class covers authentication bypass, weak credential handling, and insecure session management. Unlike injection or XSS — which are data-flow vulnerabilities with clear source→sink patterns — authentication vulnerabilities often manifest as **missing or incorrect security logic**: a JWT verified without checking expiry, a session not regenerated after login, a password compared with non-constant-time equality. Apply the source→sink→flow→sanitization methodology, but also look for required security steps that are absent.

**Tracing missing checks**: For a custom JWT verifier, trace the token from receipt (source) through parsing to each claim extracted. The vulnerability is any required check that is NOT performed. For example: JWT token from Authorization header → split on '.' → Base64-decode payload → parse JSON → extract `sub` claim → [exp claim NEVER extracted or compared to current time] → return `Ok user_id`. The missing step (exp validation) is the finding. Your "flow" terminates at where the absent check SHOULD be.

### Sources (Authentication Material)

These are credentials, tokens, and session identifiers that enter the authentication boundary and must be properly validated before granting access.

**OCaml / Dream:**
- `Dream.header "Authorization"` — Bearer tokens, Basic auth credentials
- `Dream.cookie` — session cookies, remember-me tokens
- `Dream.body` / `Dream.form` — login form credentials (username, password)
- `Dream.query` / `Dream.param` — password reset tokens, email verification tokens in URLs
- Custom JWT extraction from request headers or cookies

**JavaScript / Express:**
- `req.headers.authorization` / `req.get('Authorization')` — Bearer tokens, Basic auth
- `req.cookies` / `req.signedCookies` — session cookies
- `req.body.username` / `req.body.password` — login form credentials
- `req.query.token` / `req.params.token` — reset and verification tokens in URLs
- `req.session` — express-session data (session ID in cookie, data server-side)

**Python / Django / Flask:**
- `request.META['HTTP_AUTHORIZATION']` / `request.headers.get('Authorization')` — auth header
- `request.COOKIES` (Django) / `request.cookies` (Flask) — session cookies
- `request.POST` (Django) / `request.form` (Flask) — login form credentials
- `request.GET` (Django) / `request.args` (Flask) — reset tokens, verification tokens in URLs

### Sinks (Authentication Decision Points)

**Token and JWT Verification:**
- **OCaml**: `Jose.Jwt.verify` / `Jose.Jwt.unsafe_of_string` — JWT verification; custom token comparison functions; any function that extracts claims from a JWT and uses them for access decisions. Custom implementations using `Base64.decode_exn`, `Yojson.Basic.from_string`, and `Yojson.Basic.Util.member` are also sinks — check whether `exp` is extracted and compared to the current time.
- **JavaScript**: `jwt.decode(token)` from `jsonwebtoken` — decodes WITHOUT verifying signature (dangerous if used for auth decisions); `jwt.verify(token, secret)` — verifies signature (correct, but check options for `algorithms`, `maxAge`, `audience`, `issuer`); `jose` library `jwtVerify` / `jwtDecrypt`
- **Python**: `jwt.decode(token, options={"verify_signature": False})` from PyJWT — explicitly skipping verification; `jwt.decode(token, key, algorithms=[...])` — correct usage; `itsdangerous.URLSafeTimedSerializer` — signed token verification

**Password Comparison and Storage:**
- **OCaml**: Direct string comparison (`String.equal password hash`, `password = stored`) — not timing-safe and not hashing; `Bcrypt.verify` — correct usage
- **JavaScript**: `password === storedHash` — non-timing-safe direct comparison; `bcrypt.compare(password, hash)` — correct; `crypto.createHash('md5')` / `crypto.createHash('sha1')` for passwords — weak hashing
- **Python**: `password == stored_hash` — non-timing-safe; `hashlib.md5()` / `hashlib.sha1()` for passwords — weak hashing; `django.contrib.auth.hashers.check_password()` — correct; `werkzeug.security.check_password_hash()` — correct

**Session Management:**
- **OCaml**: `Dream.set_session_field` / `Dream.invalidate_session` — session lifecycle; custom session middleware
- **JavaScript**: `req.session.regenerate()` — session regeneration (its absence after login is the bug); `req.session.destroy()` — logout; cookie options missing `secure`, `httpOnly`, `sameSite`
- **Python**: `request.session.cycle_key()` — Django session regeneration (its absence after login is the bug); `session.clear()` / `session.flush()` — logout; `SESSION_COOKIE_SECURE` / `SESSION_COOKIE_HTTPONLY` settings

**Auth Middleware and Decorators (absence is the vulnerability):**
- **OCaml**: Dream middleware that checks auth state — look for routes defined without auth middleware in the pipeline (e.g., `Dream.get "/admin/users" handler` without an auth middleware wrapping that route or scope)
- **JavaScript**: `passport.authenticate()`, custom `isAuthenticated` middleware — look for `router.get('/admin/...', handler)` without `passport.authenticate('session')` or an `isAuthenticated` check in the middleware chain
- **Python**: `@login_required`, `@permission_required` decorators — look for view functions handling sensitive resources without these decorators; DRF `ViewSet` with `permission_classes = [AllowAny]` or `permission_classes = []` on endpoints that should require authentication

**OAuth Flow Validation (when OAuth is present):**
- Missing `state` parameter validation in OAuth callback endpoints — enables CSRF against the OAuth flow (attacker initiates OAuth, victim completes it, attacker's account gets linked)
- `redirect_uri` constructed from user input without strict allowlist validation — enables open redirect or authorization code theft
- Authorization code used without binding to the originating session

### Sanitization Assessment

**Adequate — these patterns implement authentication correctly:**
- Password hashing with key-stretching algorithms: `bcrypt`, `argon2`, `scrypt` with appropriate work factors; Django's `make_password()` / `check_password()` (uses PBKDF2 with high iterations by default); Node.js `bcrypt.hash()` / `bcrypt.compare()`
- JWT verification with full validation: `jwt.verify(token, secret, { algorithms: ['HS256'], maxAge: '1h' })` — checks signature, expiry, and restricts algorithms; PyJWT `jwt.decode(token, key, algorithms=['HS256'])` with `require=['exp']`
- Timing-safe comparison: `crypto.timingSafeEqual(a, b)` in Node.js; `hmac.compare_digest(a, b)` in Python; `Eqaf.equal` in OCaml — constant-time comparison prevents timing attacks on token/secret comparison
- Session regeneration after authentication state change: calling `req.session.regenerate()` (Express) or `request.session.cycle_key()` (Django) immediately after successful login
- Secure cookie configuration: `secure: true`, `httpOnly: true`, `sameSite: 'strict'` or `'lax'` on session cookies
- Framework authentication: passport.js strategies with proper configuration; Django `AuthenticationMiddleware` with `LoginRequiredMiddleware`; DRF `TokenAuthentication` / `JWTAuthentication` with proper settings

**Inadequate — these patterns have authentication weaknesses:**
- `jwt.decode()` without signature verification — attacker can forge arbitrary claims
- JWT accepting `algorithm: 'none'` — allows unsigned tokens; or `algorithms` list including both symmetric and asymmetric (`['HS256', 'RS256']`) — enables algorithm confusion attacks where attacker signs HS256 token with the RS256 public key
- MD5, SHA1, or unsalted SHA256 for password hashing — fast hashes enable brute force
- Plain string equality (`==`, `===`, `String.equal`) for comparing secrets, tokens, or HMAC digests — timing side channel
- Session not regenerated after login — enables session fixation if attacker can set a session ID before victim authenticates
- Hardcoded secrets or signing keys in source code — keys should come from environment or secret management
- Missing expiry check on JWTs or reset tokens — tokens valid indefinitely
- Password reset tokens generated with weak randomness (`Math.random()`, `random.random()`) instead of cryptographic randomness (`crypto.randomBytes`, `secrets.token_urlsafe`, `os.urandom`)

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble authentication vulnerabilities but are not exploitable:
- `jwt.decode()` used only to read non-security-critical claims from an already-verified token (e.g., extracting display name for UI after verification happened upstream)
- bcrypt or argon2 with work factors that seem low but are within accepted ranges — work factor tuning is a configuration choice, not a code vulnerability
- Internal service-to-service authentication using shared secrets or mTLS — different trust model than user-facing auth
- Rate limiting implemented at infrastructure level (reverse proxy, API gateway, WAF) rather than in application code — absence in app code does not mean it is missing
- Session handling in test fixtures, mock implementations, or development-only code paths
- Logout implementations that clear session state without explicit token revocation — this is standard practice when tokens have short expiry
- Password complexity validation logic — input validation, not an authentication mechanism vulnerability
- Token refresh flows where the refresh token has longer expiry than the access token — this is the intended design pattern|}

let authz_section =
  {|## Vulnerability Class: Authorization (AuthZ)

This class covers authorization bypass, privilege escalation, and insecure direct object references (IDOR). Unlike authentication (which asks "who are you?"), authorization asks "are you allowed to do this?" Authorization vulnerabilities assume the user IS authenticated but can access resources or perform actions beyond their granted permissions. These vulnerabilities often manifest as **missing checks** — an endpoint that retrieves a resource by ID without verifying the requester owns it, or a mutation endpoint that lacks a role guard. Apply the source→sink→flow→sanitization methodology, but recognize that the "sanitization" here is the authorization check itself, and its absence is the vulnerability.

### Sources (Resource Identifiers and Permission Context)

These are request parameters that identify resources or actions, combined with the authenticated user's identity and role claims. The vulnerability arises when the resource identifier flows to a data operation without being validated against the user's permissions.

**OCaml / Dream:**
- `Dream.param` — resource ID in URL path (e.g., `/users/:id/profile`, `/orders/:order_id`)
- `Dream.query` — resource identifiers or filter parameters in query string
- `Dream.body` / `Dream.form` — resource IDs or ownership-relevant fields in POST/PUT body
- Role/permission claims extracted from session or JWT middleware (e.g., `Dream.session_field "role"`)

**JavaScript / Express:**
- `req.params.id` / `req.params.resourceId` — resource identifiers in URL path
- `req.query.userId` / `req.query.tenantId` — resource identifiers in query string
- `req.body.resourceId` / `req.body.userId` — resource identifiers in request body
- `req.user` — authenticated user object from passport or JWT middleware (contains role, permissions, user ID)
- `req.headers['x-tenant-id']` — tenant identifiers in custom headers

**Python / Django / Flask:**
- `self.kwargs['pk']` / `self.kwargs['id']` — path parameters in Django class-based views
- `request.query_params` (DRF) / `request.GET` (Django) / `request.args` (Flask) — query parameters with resource IDs
- `request.data` (DRF) / `request.POST` (Django) / `request.form` (Flask) — body parameters with resource IDs
- `request.user` — authenticated user object (Django/DRF); `g.user` or `current_user` (Flask-Login)
- URL path parameters via `<int:pk>` (Django) or `<int:id>` (Flask) route definitions

### Sinks (Authorization Decision Points)

**Resource Access by Identifier (IDOR Risk):**
- **OCaml**: Database queries that fetch a resource by user-supplied ID without scoping to the current user — e.g., `Db.find ~id:(Dream.param request "id")` without adding an `owner_id` condition; Caqti queries with `WHERE id = ?` but no `AND owner_id = ?`
- **JavaScript**: `Model.findById(req.params.id)` / `Model.findOne({ _id: req.params.id })` — fetches any resource regardless of ownership; `db.query("SELECT * FROM resources WHERE id = $1", [req.params.id])` without ownership filter
- **Python**: `Model.objects.get(pk=pk)` without ownership filter; DRF `ViewSet` with `queryset = Model.objects.all()` and no `get_queryset()` override to scope by user; `session.query(Model).get(id)` in SQLAlchemy without ownership check

**Data Mutation Operations (update, delete without ownership):**
- **OCaml**: `Db.update ~id` or `Db.delete ~id` using a user-supplied ID without verifying the current user owns the resource. Watch for the pattern where the authenticated user object (from `Session.get_user` or middleware) is in scope but absent from the DB call — `user.id` appears only in logging or response formatting rather than as a filter condition.
- **JavaScript**: `Model.findByIdAndUpdate(req.params.id, req.body)` / `Model.findByIdAndDelete(req.params.id)` — modifies or deletes any resource; `db.query("DELETE FROM resources WHERE id = $1", [req.params.id])` without ownership condition
- **Python**: `Model.objects.filter(pk=pk).update(...)` / `Model.objects.filter(pk=pk).delete()` without ownership scoping; `instance.delete()` after `get_object()` without ownership validation

**Administrative and Privileged Operations:**
- **OCaml**: Route handlers for admin paths (`/admin/...`) without middleware that checks the user's role or permissions; Dream route groups without an authorization middleware in the middleware pipeline
- **JavaScript**: Express routes for admin functionality without role-checking middleware (e.g., `router.delete('/users/:id', handler)` without `requireRole('admin')` middleware)
- **Python**: Django views without `@permission_required` or `@user_passes_test` decorators; DRF ViewSets with `permission_classes = []` or `permission_classes = [IsAuthenticated]` on admin-only endpoints (should be `IsAdminUser` or a custom permission); Flask routes without `@roles_required` or equivalent

**Bulk and Cross-Tenant Operations:**
- Endpoints that accept lists of resource IDs without validating ownership of each ID
- Export or reporting endpoints that aggregate data across users/tenants without scoping
- Search or filter endpoints where a user-supplied `tenant_id` or `org_id` parameter overrides the authenticated user's tenant

**Mass Assignment (privilege escalation via field overwriting):**
- **JavaScript**: `Model.findByIdAndUpdate(id, req.body)` — user can set `role: "admin"` or `isAdmin: true` in the request body if all fields are accepted
- **Python**: `serializer.save()` in DRF where the serializer includes fields like `role`, `is_staff`, `is_superuser`, `tenant_id` that should not be user-writable; `Model.objects.create(**request.data)` passing unfiltered user input
- **OCaml**: Deserializing user-supplied JSON directly into a record type that includes privilege-relevant fields (e.g., `user_of_yojson body_json` where the type includes a `role` field) without filtering before persistence

### Sanitization Assessment

**Adequate — these patterns implement authorization correctly:**
- Ownership-scoped database queries: every query for user resources includes the authenticated user's ID as a filter condition (e.g., `Model.objects.filter(owner=request.user, pk=pk)` in Django, `WHERE id = ? AND owner_id = ?` with the current user's ID in SQL)
- DRF `get_queryset()` override that scopes to the authenticated user: `return Model.objects.filter(owner=self.request.user)` — all detail/update/delete operations go through this scoped queryset
- Authorization middleware applied at the route or router level covering all child routes (e.g., Dream middleware pipeline wrapping a scope, Express `router.use(requireAuth)` before all route handlers)
- RBAC framework integration: DRF permission classes (`IsAdminUser`, custom `IsOwner`), CASL abilities in Express, casbin policies — consistently applied to all endpoints
- Explicit field allowlists for mass assignment: DRF serializer with explicit `fields` list excluding privilege fields; Express/Mongoose handlers that destructure or pick only allowed fields from `req.body` before passing to the update operation; strong parameters pattern
- Tenant isolation at the query layer: tenant ID derived from the authenticated session (not from user input), applied to all database queries via middleware, query scoping, or row-level security

**Inadequate — these patterns have authorization weaknesses:**
- Client-side-only authorization: hiding UI elements (buttons, menu items) without server-side checks — attackers bypass the UI entirely
- Role check without ownership check: verifying the user is authenticated or has a role, but not verifying they own the specific resource they are accessing
- Inconsistent authorization across HTTP methods: checking permissions on GET but not on PUT/PATCH/DELETE for the same resource, or protecting the list endpoint but not the detail endpoint
- User-supplied tenant or organization ID: accepting `tenant_id` from the request instead of deriving it from the authenticated session — allows cross-tenant access
- Authorization check in the wrong order: fetching the resource first, then checking authorization — may leak information about resource existence through timing or error differences
- Blanket `IsAuthenticated` permission on endpoints that need ownership or role checks — authentication is not authorization
- Mass assignment without field filtering: accepting all user-supplied fields including privilege-escalation fields like `role`, `is_admin`, `is_staff`, `tenant_id`
- UUIDs or random resource identifiers as the sole authorization mechanism: obscurity reduces discoverability but does not prevent access if an attacker obtains or guesses a valid ID

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble authorization vulnerabilities but are not exploitable:
- Public resources intentionally accessible to all authenticated users: shared dashboards, public profiles, published content, system-wide settings — verify these are designed to be public before dismissing
- Authorization enforced at a higher scope than the individual route: middleware applied at the router, scope, or application level that covers all child routes — check the middleware pipeline, not just the individual handler
- Read-only endpoints for non-sensitive, non-personal data: public API endpoints serving catalog data, documentation, or configuration that does not vary by user
- Internal service-to-service calls that bypass user-level authorization by design: requests authenticated via mTLS, service accounts, or internal API keys with their own authorization model
- Django admin views with `@staff_member_required` — the admin site has its own permission model where staff/superuser overrides are intentional
- DRF ViewSets where `get_queryset()` already scopes to the user but the `queryset` class attribute shows `Model.objects.all()` — the class attribute is used for router registration and schema generation, not for actual data queries when `get_queryset()` is overridden
- Test fixtures, seed data scripts, or management commands that operate without user context — these run in a privileged context by design
- Authorization logic delegated to a separate authorization service (e.g., OPA, Authzed/SpiceDB, Ory Keto) called via the network — the check may not be visible in the application code|}

let ssrf_section =
  {|## Vulnerability Class: Server-Side Request Forgery (SSRF)

This class covers vulnerabilities where user-controlled input influences the target of an outbound HTTP request made by the server. The attacker's goal is to make the server send requests to unintended destinations: internal services (databases, admin panels, caches), cloud instance metadata endpoints (e.g., AWS IMDSv1 at 169.254.169.254), private network hosts, or arbitrary external servers. SSRF is dangerous even when the response is not returned to the attacker ("blind SSRF") — the server's request alone can trigger actions on internal services, scan ports, or exfiltrate data via DNS. Apply the source→sink→flow→sanitization methodology, and pay special attention to URL construction, redirect following, and the gap between URL validation time and request time (DNS rebinding).

### Sources (User-Controlled URL Input)

These are request parameters, stored values, or uploaded content that supply a URL, hostname, or URL component used to construct an outbound request.

**OCaml / Dream:**
- `Dream.query` — URL or hostname in query parameters (e.g., `?url=...`, `?callback=...`, `?redirect=...`)
- `Dream.param` — URL-like path parameters (e.g., `/proxy/:target_url`)
- `Dream.body` / `Dream.form` — URLs in POST body (webhook registration endpoints, "import from URL" features, avatar URL fields)
- `Dream.header` — headers like `X-Forwarded-Host` or `Referer` used to construct outbound URLs

**JavaScript / Express:**
- `req.query.url` / `req.query.callback` / `req.query.redirect` — URL in query string
- `req.body.webhookUrl` / `req.body.imageUrl` / `req.body.feedUrl` — URLs in request body (webhook configs, media imports, RSS feeds)
- `req.params` — URL-like path parameters
- `req.headers.referer` / `req.headers['x-forwarded-host']` — headers used to construct request targets

**Python / Django / Flask:**
- `request.GET['url']` / `request.POST['url']` — URL parameters (Django)
- `request.data['webhook_url']` / `request.data['import_url']` — body URLs (DRF)
- `request.args['callback']` / `request.json['url']` — URL parameters (Flask)
- `request.META['HTTP_REFERER']` / `request.META['HTTP_X_FORWARDED_HOST']` — headers used in URL construction (Django)

**Cross-language second-order sources:**
- URLs stored in database and later fetched (webhook configurations, user-configured integration endpoints, avatar URLs, import settings)
- URLs in user-uploaded files: XML external entity references (XXE→SSRF chain), SVG with external image/stylesheet references, HTML with resource links, YAML/JSON config files with URL fields
- Redirect URLs from OAuth or SAML flows that are followed server-side
- URLs from message queues or event payloads that trigger server-side fetches

### Sinks (Outbound Request Operations)

**OCaml:**
- `Cohttp_lwt_unix.Client.get` / `Client.post` / `Client.call` — Cohttp HTTP client making requests to user-influenced URIs
- `Piaf.Client.get` / `Piaf.Client.post` / `Piaf.Client.Oneshot.get` / `Piaf.Client.Oneshot.post` — Piaf HTTP/2 client (both persistent and one-shot APIs)
- `Ezcurl.get` / `Ezcurl.post` — curl bindings for OCaml
- Any function that accepts a `Uri.t` constructed from user input and issues an outbound HTTP request
- `Dream.redirect` — only an SSRF sink if the server subsequently fetches the redirect target; if only the client's browser follows the redirect, it is an open redirect issue, not SSRF (see False Positive Patterns)

**JavaScript / Node.js:**
- `fetch(url)` / `fetch(new URL(userInput))` — native Fetch API (Node.js >= 18) or `node-fetch` package (older Node.js; follows redirects by default)
- `axios.get(url)` / `axios.post(url)` / `axios(config)` / `axios.request({ url })` — axios client
- `http.get(url)` / `http.request(url)` / `https.get(url)` — Node.js built-in HTTP modules
- `got(url)` / `superagent.get(url)` / `needle.get(url)` — popular HTTP libraries
- `res.redirect(userInput)` — Express redirect; only SSRF if the server later fetches the redirect target (otherwise open redirect, not SSRF)

**Python:**
- `requests.get(url)` / `requests.post(url)` / `requests.request(method, url)` — requests library
- `urllib.request.urlopen(url)` / `urllib.request.Request(url)` — stdlib
- `httpx.get(url)` / `httpx.AsyncClient().get(url)` — httpx async/sync client
- `aiohttp.ClientSession().get(url)` — aiohttp async client
- `urllib3.PoolManager().request(method, url)` — urllib3
- `redirect(url)` (Django) / `redirect(url)` (Flask) — redirect responses; only SSRF if the server later fetches the target (otherwise open redirect, not SSRF)

**Cross-language sink patterns:**
- Image/media processing pipelines that download from a user-supplied URL (thumbnail generation, avatar fetching, OG image scraping)
- Webhook delivery systems that POST to user-registered callback URLs
- "Import from URL" features that fetch and parse remote content (RSS/Atom feeds, CSV imports, API integrations)
- URL preview/unfurling (link previews in chat applications, OpenGraph metadata fetching)
- PDF generation from user-supplied URLs (e.g., headless browser navigating to a URL)

### Sanitization Assessment

**Adequate — these patterns prevent SSRF effectively:**
- URL allowlist with explicit domain matching: the target hostname is checked against a hardcoded list of permitted domains using exact match or controlled suffix matching (e.g., allowing `*.example.com` via proper domain-level comparison, not string suffix)
- Scheme restriction to `http` and `https` only, rejecting `file://`, `gopher://`, `dict://`, `ftp://`, `data://`, and all other schemes — applied before the request is made
- Resolved-IP validation at connection time: the application resolves the hostname and validates the resulting IP address is not in private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, ::1, fc00::/7, fe80::/10) using a custom DNS resolver or socket-level hook that enforces the check at connection time, preventing DNS rebinding
- Dedicated egress proxy with network-level restrictions (e.g., Smokescreen, an HTTP proxy that blocks requests to internal IPs regardless of DNS resolution)
- Redirect validation: when following redirects, each redirect target is re-validated against the same allowlist/IP restrictions — the HTTP client is configured to not follow redirects automatically, or a redirect hook re-checks each hop
- Cloud metadata endpoint protection: AWS IMDSv2 enforcement (requires a PUT request with a token header) with IMDSv1 disabled; GCP metadata requires `Metadata-Flavor: Google` header; Azure IMDS requires `Metadata: true` header — these mitigate cloud metadata SSRF at 169.254.169.254, but are defense-in-depth (the application should still prevent requests to internal IPs)

**Inadequate — these patterns have SSRF weaknesses:**
- IP address blocklist without DNS rebinding protection: checking the hostname's resolved IP before the request but using a separate resolution for the actual connection — attacker's DNS server returns a public IP for the validation check, then a private IP for the actual request (time-of-check/time-of-use)
- URL string matching or substring checks (e.g., `url.includes('localhost')`, `url.startsWith('http')`) — trivially bypassable with `http://localhost@evil.com`, `http://evil.com#localhost`, URL encoding, or alternate IP representations
- Hostname validation without IP resolution: checking the hostname string but not the IP it resolves to — attacker registers a domain pointing to 127.0.0.1 or an internal IP
- Incomplete scheme blocking: blocking `file://` but allowing `gopher://` (can be used to send arbitrary TCP data) or `dict://` (can probe services)
- Regex-based URL parsing: URL syntax is complex and regex implementations frequently disagree with actual HTTP client URL parsers, creating bypass opportunities
- Blocklist of known-bad IP addresses without covering all representations: blocking `127.0.0.1` but not `0x7f000001`, `2130706433`, `0177.0.0.1`, `127.1`, `0`, `[::]`, or IPv6-mapped IPv4 like `[::ffff:127.0.0.1]`
- Redirect following without re-validating each hop: initial URL passes validation, but a redirect leads to an internal address
- Validating the URL but allowing the user to also control HTTP headers (e.g., `Host` header override that routes the request to a different backend)

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble SSRF but are not exploitable:
- Hardcoded URLs or URLs assembled from application constants and environment variables set at deployment time — no user control at runtime means no SSRF
- Outbound requests to fixed, known API endpoints where only a path segment or query parameter (not the scheme+host) is user-controlled and path traversal does not apply (e.g., `https://api.stripe.com/v1/charges/` + charge_id)
- URL construction where the base URL (scheme + host + port) is hardcoded and the user-controlled portion is a path parameter that is validated or URL-encoded before appending
- Webhook delivery systems where URLs are validated at registration time by an admin-only endpoint and the stored URL is used as-is for delivery — the trust boundary was enforced at write time
- Health check or monitoring endpoints that call fixed internal URLs defined in application configuration
- Test fixtures, seed data scripts, or development-only code that uses localhost URLs — not reachable in production
- Requests routed through a properly configured egress proxy (e.g., Smokescreen, Envoy with egress filtering) that blocks internal destinations at the network level
- `Dream.redirect` / `res.redirect()` / `redirect()` returning a redirect response to the client (the browser follows the redirect, not the server) — this is an open redirect issue, not SSRF, unless the server subsequently follows the redirect itself|}

let path_traversal_section =
  {|## Vulnerability Class: Path Traversal and File Exposure

This class covers vulnerabilities where user-controlled input influences a filesystem path, letting an attacker read, write, or overwrite files outside the directory the application intended. The classic payload escapes upward with `../` sequences (`../../etc/passwd`, `..\..\windows\win.ini`), but the class also covers absolute-path injection (the user supplies `/etc/passwd` and the application joins it onto a base directory that is then discarded), symlink following, archive extraction that writes outside the extraction root ("zip slip"), and user-controlled file *writes* that clobber application files. Apply the source→sink→flow→sanitization methodology, and pay special attention to the difference between normalizing a path and confining it: a path can be perfectly normalized and still point outside the intended root.

The decisive question is always **containment**: after all normalization, is the resolved absolute path provably inside the intended base directory? A check that inspects the path *before* resolution is usually inadequate, because `..` segments, symlinks, URL-decoding, and Unicode normalization can all change where the path lands.

### Sources (User-Controlled Path Input)

These are request parameters, stored values, or archive/upload contents that supply a filename, path segment, or full path used to build a filesystem operation.

**OCaml / Dream:**
- `Dream.param` — path segments used as filenames (e.g., `/files/:name`, `/download/:doc`)
- `Dream.query` — filenames or paths in query parameters (e.g., `?file=...`, `?path=...`, `?template=...`)
- `Dream.body` / `Dream.form` — paths in POST bodies (export targets, report names, config paths)
- `Dream.upload` — the client-supplied filename of a multipart upload, used to choose a destination path
- `Dream.header` — headers used to derive filenames (rare, but `Content-Disposition` values sometimes are)

**JavaScript / Express:**
- `req.params.filename` / `req.params[0]` — path segments, especially wildcard routes like `/files/*`
- `req.query.file` / `req.query.path` / `req.query.template` — filenames in query strings
- `req.body.filename` / `req.body.exportPath` — paths in request bodies
- `req.file.originalname` / `req.files[].originalname` — client-supplied upload filenames (multer); the client fully controls this string
- Entry names from archive libraries (`yauzl`, `unzipper`, `tar`) when extracting user-uploaded archives

**Python / Django / Flask:**
- `request.args['file']` / `request.args['name']` / `request.args['path']` — Flask query parameters
- `request.GET['file']` / `request.POST['path']` — Django parameters
- `request.files['upload'].filename` — client-supplied upload filename (Flask/Werkzeug); attacker-controlled
- Flask/Django URL converters that capture path-like values, especially `<path:...>` which deliberately permits `/`
- `zipfile.ZipFile.namelist()` / `tarfile.TarFile.getnames()` entries from a user-supplied archive
- `request.data` / `request.json` fields naming a file, template, or output location

**Cross-language second-order sources:**
- Filenames stored in a database at upload time and later used to build a read or delete path
- Paths inside user-supplied manifests, config files, or job payloads consumed by a worker
- Archive member names during extraction (zip slip / tar slip) — the archive itself is the attacker's input
- Filenames derived from user-controlled metadata such as document titles or export names
- Symlinks inside a user-supplied archive or a user-writable directory, resolved later by an unrelated read

### Sinks (Filesystem Operations)

**OCaml:**
- `open_in` / `open_in_bin` / `open_out` / `open_out_bin` — stdlib file open on a user-influenced path
- `Stdlib.really_input_string` after an attacker-influenced `open_in` — the open is the sink
- `Filename.concat` / `Filename.dirname` / `Filename.basename` — path construction; `Filename.concat base user_input` does NOT confine, because an absolute `user_input` or `..` segments escape `base`
- `Unix.openfile` / `Unix.unlink` / `Unix.rename` / `Unix.stat` / `Unix.lstat` — direct syscall wrappers
- `Lwt_io.open_file` / `Lwt_io.with_file` / `Lwt_unix.openfile` — Lwt file I/O
- `Dream.from_filesystem` / `Dream.static` — static file serving; safe only when the path argument is confined (see False Positive Patterns)
- `Bos.OS.File.read` / `Bos.OS.File.write` / `Bos.OS.Dir.create` — Bos filesystem operations

**JavaScript / Node.js:**
- `fs.readFile` / `fs.readFileSync` / `fs.createReadStream` — file reads on a user-influenced path
- `fs.writeFile` / `fs.writeFileSync` / `fs.createWriteStream` / `fs.appendFile` — file writes (overwrite risk, not just disclosure)
- `fs.unlink` / `fs.rm` / `fs.rmdir` / `fs.rename` — destructive operations
- `path.join(base, userInput)` / `path.resolve(base, userInput)` — path construction; `path.join` does NOT confine (`..` escapes), and `path.resolve` treats an absolute `userInput` as the whole path, discarding `base` entirely
- `res.sendFile(userPath)` / `res.download(userPath)` — Express file responses; `sendFile` confines only when a `root` option is supplied
- `express.static(dir)` — safe by itself; unsafe when combined with custom path handling before it
- `require(userInput)` / dynamic `import(userInput)` — path-controlled module load (code execution, not just disclosure)

**Python:**
- `open(path)` — the canonical sink for read and write modes alike
- `os.path.join(base, user_input)` — does NOT confine: an absolute `user_input` discards `base`, and `..` segments escape it
- `os.remove` / `os.unlink` / `os.rename` / `os.replace` / `shutil.move` / `shutil.rmtree` — destructive operations
- `shutil.copy` / `shutil.copyfile` — copy with a user-influenced source or destination
- `send_file(path)` / `send_from_directory(dir, filename)` (Flask) — `send_file` with a user-controlled path is a direct sink; `send_from_directory` is safer but historically had bypasses on some versions and still requires a trusted `dir`
- `django.http.FileResponse(open(path, 'rb'))` — Django file response
- `pathlib.Path(base) / user_input` — the `/` operator does NOT confine; an absolute `user_input` replaces the base
- `zipfile.ZipFile.extract` / `extractall` / `tarfile.TarFile.extract` / `extractall` — extraction sinks; without member validation these write anywhere the process can (Python 3.12+ offers `filter='data'`)
- `os.makedirs(path)` — directory creation at a user-influenced location

**Cross-language sink patterns:**
- Static file / document download endpoints that accept a filename or document id
- Template or partial loading where the template name is user-influenced (can also become SSTI)
- Log or report writers that build the output filename from user input
- Upload handlers that store a file under its client-supplied name
- Archive extraction of user-uploaded zip/tar files
- Backup, import, and export features that accept a path
- Image/asset resizers that read a source path derived from a request parameter

### Sanitization Assessment

**Adequate — these patterns prevent path traversal effectively:**
- Resolve-then-verify containment: the path is fully resolved to an absolute, symlink-free form (`realpath`, `Unix.realpath`, `fs.realpathSync`, `os.path.realpath`, `Path.resolve`) and then checked to be inside the intended base directory using a **path-segment-aware** comparison (i.e., the resolved path equals the base or starts with base + separator), with the check performed after resolution and before the operation
- Indirect reference: the user supplies an opaque id, and the application looks the real path up in a database, allowlist, or fixed mapping — the user's string never reaches the filesystem
- Strict allowlist of permitted filenames or extensions, matched exactly against a fixed set
- Basename-only extraction combined with a fixed directory: taking `os.path.basename` / `Filename.basename` / `path.basename` (which strips every directory component) and joining it onto a trusted base, so no user-supplied separator survives
- A strict character allowlist that rejects (rather than strips) anything outside e.g. `[A-Za-z0-9._-]`, with a separate explicit rejection of `..` as a whole component
- Generated storage names: uploads are stored under a server-generated name (UUID, content hash) and the client filename is kept only as display metadata, never as a path
- Serving through an API that confines by construction: `res.sendFile(name, { root: safeDir })`, `Dream.from_filesystem safe_dir`, or `send_from_directory(trusted_dir, name)` where `trusted_dir` is not user-influenced
- Archive extraction that validates each member's resolved destination is inside the extraction root before writing, and rejects absolute members, `..` members, and symlink/hardlink members (or Python 3.12+ `extractall(filter='data')`)
- OS-level confinement that the reviewed code genuinely runs under: `chroot`, a mount namespace, or `openat` with `RESOLVE_BENEATH`

**Inadequate — these patterns have traversal weaknesses:**
- Single-pass stripping of `../`: replacing `"../"` with `""` once is bypassed by `....//`, `..././`, or nesting that reassembles a traversal after the replacement
- Blocklisting the literal `".."` string without normalizing first: bypassed by URL encoding (`%2e%2e%2f`), double encoding (`%252e%252e%252f`), overlong UTF-8, backslashes on Windows (`..\`), or mixed separators
- Checking the path *before* normalization or resolution, then operating on the raw value — the check and the operation see different paths (time-of-check/time-of-use)
- `startsWith` / prefix comparison on strings without a separator boundary: base `/srv/data` also "contains" `/srv/data-evil`, so a sibling directory passes the check
- `path.join(base, user)` / `os.path.join(base, user)` / `Filename.concat base user` treated as confinement — it is only concatenation; `..` escapes and (for `join`/`resolve` in Node and Python) an absolute `user` discards `base` entirely
- Normalizing with `path.normalize` / `os.path.normpath` but never comparing the result against the base — normalization resolves `..` textually but does not confine, and `normpath` does not resolve symlinks
- Validating the filename but appending a user-controlled extension or suffix, or vice versa
- Rejecting `..` but permitting an absolute path, which needs no `..` to escape
- Ignoring symlinks: the path contains no `..` and sits inside the base, but a symlink within the base points outside it (`realpath`/`lstat` checks are required, and matter most where users can create files in the base)
- Relying on the web framework's URL normalization to stop traversal: decoding and normalization differ between the proxy, the framework router, and the filesystem call
- Null-byte or control-character truncation in FFI or older runtimes, where `safe.txt\0../../etc/passwd` truncates at the null byte in a C call
- Archive extraction that checks member names as strings but not the resolved destination, or that trusts member type (symlink members can redirect later writes)

### Common False Positive Patterns — DO NOT REPORT

These are safe patterns that may superficially resemble path traversal but are not exploitable:
- Paths built entirely from application constants, environment variables, or configuration set at deployment time — no runtime user control means no traversal
- `path.join` / `os.path.join` / `Filename.concat` on values that are all server-controlled (a config directory plus a hardcoded filename)
- A user-influenced value that has already been reduced to a bare basename (`basename` applied, or a strict `[A-Za-z0-9._-]` allowlist enforced with rejection) before it reaches the join
- Indirect lookups where the user-supplied id is resolved through a database or fixed mapping to a server-controlled path
- Static file middleware used as documented with a fixed root and no custom path preprocessing (`express.static(dir)`, `Dream.from_filesystem safe_dir`, `send_from_directory(trusted_dir, name)` on a maintained version)
- Uploads stored under a server-generated name where the client filename is retained only as display metadata
- Build scripts, test fixtures, migrations, and developer tooling that read local paths — not attacker-reachable in production, unless the reviewed change puts them on a request path
- Reads confined to a directory whose entire contents are already public (e.g. a static asset directory) where the resolved path is verified inside it and the files carry no secrets — disclosure of already-public data is not a finding
- Paths derived from an authenticated administrator's input where the application's threat model explicitly trusts that role, and the change does not widen who can reach it
- Temporary files created with a library that generates its own unpredictable name (`Filename.temp_file`, `tempfile.NamedTemporaryFile`, `fs.mkdtemp`) and never joins user input onto it|}

let policy_regression_section =
  {|## Vulnerability Class: Security Policy Regression

This class covers changes where the diff itself broadens privilege, grants a new privileged capability, or weakens a named
security control. These are not runtime source-to-sink bugs: do not suppress them because no user-controlled request
parameter exists. The proof is a policy/control proof.

### Sources (Changed Policy or Control Entry)

The source is the exact changed line that alters policy state:
- Sudoers or configuration management entries that grant `NOPASSWD`, `ALL=(ALL)`, root execution, or broad commands such
  as `/usr/bin/systemctl`
- IAM policy statements, Terraform IAM resources, cloud role assignments, RBAC role bindings, Kubernetes `Role`,
  `ClusterRole`, `RoleBinding`, or `ClusterRoleBinding`
- GitHub Actions or CI configuration that changes job permissions, event triggers, OIDC token access, deployment
  credentials, or checkout/build behavior
- Kubernetes workload security context changes such as `privileged: true`, `hostPath`, `hostNetwork`, host namespaces,
  `runAsUser: 0`, or `allowPrivilegeEscalation: true`
- Application/framework configuration that disables TLS/certificate verification, auth checks, CSRF protection,
  tenant/user scoping, allowlists, or other named security controls

### Sinks (Effective Privilege or Weakened Boundary)

The sink is the effective action or security boundary after the policy is applied:
- A named principal can run a root command without a password, restart services, write root-owned files, or execute a
  command that can be turned into code execution
- A CI job token can write repository contents, mint OIDC tokens, alter checks/deployments, or run privileged workflows in
  a context exposed to untrusted code
- A cloud, IAM, or Kubernetes subject can perform wildcard actions, access all resources, bind `cluster-admin`, run
  privileged pods, mount host paths, or reach host/network namespaces
- A control such as TLS verification, CSRF enforcement, authentication/authorization, tenant isolation, or approval gates
  is disabled or bypassed

### Policy Proof Methodology

For every candidate:
1. Identify the changed principal/grant/control line as `source`.
2. Identify the effective capability or weakened boundary as `sink`.
3. Trace `source -> effective policy/control state -> concrete action now possible` in `flow`.
4. Evaluate scoping/mitigation in `sanitization`: principal constraints, exact resource/action allowlists, conditions,
   environment restrictions, approval gates, tenant/user boundaries, or compensating controls.

Report only when the diff gives exact file/line evidence for a concrete capability. The description must name the
principal, action, resource/boundary, and why the change broadens access or weakens protection.

### Vulnerable Patterns

- `NOPASSWD: /usr/bin/systemctl` where the principal can operate arbitrary services or service actions as root
- `NOPASSWD: ALL`, `ALL=(ALL) ALL`, or equivalent broad root command grants
- IAM/RBAC policies with `Action: "*"`, `Resource: "*"`, wildcard verbs/resources, `cluster-admin`, or broad role
  bindings to service accounts used by CI or workloads
- GitHub Actions `permissions: write-all`, `contents: write`, `id-token: write`, or `pull_request_target` combined with
  code checkout/build patterns that can expose secrets or write capabilities
- `verify: false`, `rejectUnauthorized: false`, `insecure_skip_verify`, `csrf_exempt`, `allow_all`, or removed auth/CSRF
  middleware on a protected boundary

### Adequate Scoping / Common False Positive Patterns — DO NOT REPORT

- Sudo grants scoped to an exact harmless command and exact arguments, such as allowing a deploy user to run only
  `/usr/bin/systemctl reload reviewotron-readonly.service` when that unit/action cannot be influenced by the principal
- Read-only IAM/RBAC grants scoped to a named resource and namespace with no wildcard action/resource expansion
- CI permissions explicitly set to `contents: read` or least-privilege job-level permissions with no privileged event
  trigger or secret exposure path
- Security controls disabled only in tests, local development fixtures, generated examples, or comments, with production
  paths still enforcing the control
- Policy formatting, comments, or moves that do not change the effective principal/action/resource/control state|}

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
    | Security_types.Path_traversal -> path_traversal_section
    | Security_types.Policy_regression -> policy_regression_section
  in
  base ^ language_note

let build_system_prompt ~vuln_class ~language_hints =
  String.concat "\n\n"
    [ preamble; shared_methodology; vuln_class_section vuln_class ~language_hints; tools_and_output_section ]

let config ~vuln_class ~model_tier ~language_hints : Agent_runner.agent_config =
  let name = Printf.sprintf "security_analysis_%s" (Security_types.vuln_class_to_string vuln_class) in
  let system_prompt = build_system_prompt ~vuln_class ~language_hints in
  {
    name;
    system_prompt;
    model_tier;
    output_schema = Security_types.analysis_output_jsonschema;
    max_steps = 15;
    thinking_budget = None;
    effort = None;
  }

let append_regions buf regions =
  List.iter
    (fun (r : Security_types.region) -> Printf.bprintf buf "  - %s lines %d-%d\n" r.path r.start_line r.end_line)
    regions

let analysis_question = function
  | Security_types.Injection ->
    "Can any flagged externally controlled value reach a query construction or query execution sink without \
     parameterization?"
  | Xss ->
    "Can any flagged user-controlled content reach HTML, DOM, markdown-to-HTML, or template rendering without \
     context-correct escaping or sanitization?"
  | Command_injection ->
    "Can any flagged externally controlled value reach a shell command string, process invocation, or fragile escaping \
     boundary?"
  | Authn ->
    "Does the flagged authentication, token, session, password, API-key, or OAuth path accept invalid, expired, \
     forged, fallback, or otherwise unsafe credentials?"
  | Authz ->
    "Does the flagged authorization or resource-access path allow a caller to access or mutate a resource without the \
     required role, permission, ownership, or tenant boundary?"
  | Ssrf ->
    "Can any flagged externally controlled URL, host, redirect, webhook, or stored URL reach a server-side outbound \
     request without adequate destination controls?"
  | Path_traversal ->
    "Can any flagged user-controlled value influence a filesystem path so that the resolved location escapes the \
     intended base directory, exposing or overwriting an unintended file?"
  | Policy_regression ->
    "Does the flagged policy or configuration change concretely broaden privilege or weaken a named security control?"

let highest_confidence signals =
  List.fold_left
    (fun best (signal : Security_types.triage_signal) ->
      match Config_types.confidence_rank signal.confidence > Config_types.confidence_rank best with
      | true -> signal.confidence
      | false -> best)
    Security_types.Low signals

let add_analysis_scope buf triage_signals =
  match triage_signals with
  | [] -> ()
  | first :: _ ->
    let confidence = highest_confidence triage_signals in
    Printf.bprintf buf "## Analysis Scope\n\n";
    Printf.bprintf buf "**Question:** %s\n\n" (analysis_question first.vuln_class);
    Printf.bprintf buf "**Routing confidence:** %s across %d triage signal(s).\n\n"
      (Security_types.confidence_to_string confidence)
      (List.length triage_signals);
    Buffer.add_string buf
      "Start from the flagged regions and direct callees/config references. Do not perform broad repository \
       archaeology. If those bounded checks do not establish a concrete source/effect, sink/capability, and missing or \
       inadequate control, return an empty `findings` array with a short note.\n\n";
    (match confidence with
    | High ->
      Buffer.add_string buf
        "Because the routing confidence is high, fetch additional files only when they directly close a specific \
         evidence gap in an otherwise concrete chain.\n\n"
    | Medium | Low ->
      Buffer.add_string buf
        "Because the routing confidence is not high, treat this as a bounded verification pass: inspect changed \
         regions and immediate dependencies first, and stop early if the concrete chain is not emerging.\n\n")

let build_input ~diff_text ~triage_signals ~file_paths () =
  let buf = Buffer.create (String.length diff_text + 512) in
  add_analysis_scope buf triage_signals;
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
  Buffer.add_char buf '\n';
  Buffer.add_string buf Review_prompt.annotated_diff_format_explainer;
  Buffer.add_string buf "\n## Diff\n\n";
  Buffer.add_string buf diff_text;
  Buffer.contents buf

let tools ~fetch_file = [ Security_tools.make_get_file_content ~fetch_file ]
