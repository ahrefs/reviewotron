(** Deterministic security hints over changed diff hunks. *)

module ST = Security_types

type line_rule = {
  category : ST.signal_category;
  vuln_class_hint : ST.vuln_class option;
  pattern : string;
  rationale : string;
  matches : string -> bool;
}

type path_rule = {
  category : ST.signal_category;
  vuln_class_hint : ST.vuln_class option;
  pattern : string;
  rationale : string;
  matches_path : string -> bool;
}

let contains ~sub s = CCString.find ~sub s >= 0
let lower s = String.lowercase_ascii s
let lower_contains ~sub s = contains ~sub (lower s)

let contains_any needles s = List.exists (fun needle -> lower_contains ~sub:needle s) needles

let has_sql_shape s =
  let has_sql_keyword = contains_any [ "select "; "insert "; "update "; "delete "; " where "; " from "; "raw(" ] s in
  let has_execution = contains_any [ "query("; "execute("; "exec("; "raw(" ] s in
  let has_string_assembly = contains_any [ " + "; "${"; "sprintf"; "^"; "format(" ] s in
  has_sql_keyword && (has_execution || has_string_assembly)

let has_shell_shape s =
  contains_any
    [
      "sys.command";
      "unix.open_process";
      "lwt_process.shell";
      "child_process.exec";
      "execsync";
      "os.system";
      "os.popen";
      "shell=true";
      "subprocess.";
      "`";
    ]
    s

let has_html_sink_shape s =
  contains_any
    [
      "innerhtml";
      "outerhtml";
      "dangerouslysetinnerhtml";
      "insertadjacenthtml";
      "document.write";
      "dream.html";
      "render_template_string";
      "mark_safe";
      "|safe";
      "unsafe.data";
    ]
    s

let has_outbound_fetch_shape s =
  contains_any
    [ "fetch("; "http.get"; "http.post"; "requests.get"; "requests.post"; "reqwest"; "curl"; "webhook_url"; "open_uri" ]
    s

let has_path_join_shape s =
  contains_any
    [
      "filename.concat";
      "path.join";
      "path.resolve";
      "os.path.join";
      "filepath.join";
      "sendfile";
      "readfile";
      "writefile";
    ]
    s

let has_deserialization_shape s =
  contains_any
    [ "pickle.loads"; "yaml.load"; "marshal.loads"; "deserialize"; "objectinputstream"; "eval("; "from_yojson" ]
    s

let has_jwt_session_shape s =
  contains_any
    [ "jwt"; "session"; "cookie"; "password"; "oauth"; "bearer"; "api key"; "apikey"; "verifytoken"; "sign token" ]
    s

let has_security_control_shape s =
  contains_any
    [
      "sanitize";
      "escape";
      "allowlist";
      "whitelist";
      "permission";
      "authorize";
      "authenticated";
      "requireadmin";
      "policy";
      "role";
      "csrf";
      "cors";
      "origin";
      "validate";
      "validator";
      "guard";
    ]
    s

let has_stateful_shape s =
  contains_any
    [
      "balance";
      "quota";
      "inventory";
      "counter";
      "credit";
      "seat";
      "limit";
      "status";
      "idempotency";
      "transaction";
      "lock";
      "retry";
      "increment";
      "decrement";
    ]
    s

let dangerous_api_rules =
  [
    {
      category = ST.Dangerous_api;
      vuln_class_hint = Some ST.Command_injection;
      pattern = "shell/process execution";
      rationale = "Changed line invokes shell or process execution APIs that can become command injection sinks.";
      matches = has_shell_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = Some ST.Injection;
      pattern = "raw SQL/query construction";
      rationale = "Changed line appears to construct or execute a raw query string.";
      matches = has_sql_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = Some ST.Xss;
      pattern = "HTML rendering sink";
      rationale = "Changed line writes or renders HTML through an unsafe sink.";
      matches = has_html_sink_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = Some ST.Ssrf;
      pattern = "outbound URL fetch";
      rationale = "Changed line performs an outbound request that may become SSRF if target input is untrusted.";
      matches = has_outbound_fetch_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = None;
      pattern = "file path join/read/write";
      rationale = "Changed line builds or consumes filesystem paths; review path traversal and file exposure risk.";
      matches = has_path_join_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = None;
      pattern = "deserialization/eval";
      rationale = "Changed line deserializes or evaluates data; review trust boundary and input validation.";
      matches = has_deserialization_shape;
    };
    {
      category = ST.Dangerous_api;
      vuln_class_hint = Some ST.Authn;
      pattern = "JWT/session handling";
      rationale = "Changed line touches authentication token, password, cookie, or session handling.";
      matches = has_jwt_session_shape;
    };
  ]

let security_control_rules =
  [
    {
      category = ST.Changed_security_control;
      vuln_class_hint = None;
      pattern = "security control";
      rationale = "Changed line appears to modify validation, sanitization, authorization, or related control logic.";
      matches = has_security_control_shape;
    };
  ]

let stateful_rules =
  [
    {
      category = ST.Stateful_operation;
      vuln_class_hint = None;
      pattern = "stateful operation";
      rationale = "Changed line touches state transitions, quotas, balances, counters, locks, or retries.";
      matches = has_stateful_shape;
    };
  ]

let risky_path_rules =
  let mk ?hint needle rationale =
    {
      category = ST.Risky_path;
      vuln_class_hint = hint;
      pattern = "path:" ^ needle;
      rationale;
      matches_path = lower_contains ~sub:needle;
    }
  in
  [
    mk ~hint:ST.Authn "auth" "Changed file path is authentication-sensitive.";
    mk ~hint:ST.Authn "session" "Changed file path is session-sensitive.";
    mk ~hint:ST.Authz "middleware" "Changed file path is middleware-sensitive.";
    mk ~hint:ST.Authz "admin" "Changed file path is admin or access-control sensitive.";
    mk ~hint:ST.Authz "tenant" "Changed file path is multi-tenant access-control sensitive.";
    mk ~hint:ST.Authz "policy" "Changed file path is policy or permission sensitive.";
    mk "payment" "Changed file path is payment-sensitive.";
    mk "billing" "Changed file path is billing-sensitive.";
    mk ~hint:ST.Ssrf "webhook" "Changed file path is webhook-sensitive.";
    mk "parser" "Changed file path is parser-sensitive.";
    mk ~hint:ST.Ssrf "proxy" "Changed file path is proxy-sensitive.";
    mk "upload" "Changed file path is upload-sensitive.";
  ]

let basename path = path |> Filename.basename |> lower

let package_manifest_names =
  [
    "package.json";
    "package-lock.json";
    "pnpm-lock.yaml";
    "yarn.lock";
    "cargo.toml";
    "cargo.lock";
    "go.mod";
    "go.sum";
    "pyproject.toml";
    "requirements.txt";
    "gemfile";
    "gemfile.lock";
    "dune-project";
    "mix.exs";
    "mix.lock";
  ]

let sensitive_file_rules =
  [
    {
      category = ST.Sensitive_file;
      vuln_class_hint = None;
      pattern = "route/middleware/policy file";
      rationale = "Changed file appears to define routes, middleware, or policy controls.";
      matches_path = (fun path -> contains_any [ "route"; "router"; "middleware"; "policy" ] path);
    };
    {
      category = ST.Sensitive_file;
      vuln_class_hint = None;
      pattern = "workflow file";
      rationale = "Changed file is a workflow definition that can affect CI/CD execution.";
      matches_path = (fun path -> lower_contains ~sub:".github/workflows/" path);
    };
    {
      category = ST.Sensitive_file;
      vuln_class_hint = None;
      pattern = "container/infrastructure config";
      rationale = "Changed file is container or infrastructure configuration.";
      matches_path =
        (fun path ->
          let path = lower path in
          String.equal (basename path) "dockerfile"
          || contains_any [ "docker-compose"; ".tf"; ".tfvars"; "kubernetes"; "k8s" ] path);
    };
    {
      category = ST.Sensitive_file;
      vuln_class_hint = None;
      pattern = "package manifest";
      rationale = "Changed file is a package manifest or lockfile.";
      matches_path =
        (fun path ->
          let base = basename path in
          List.exists (String.equal base) package_manifest_names || Filename.check_suffix base ".opam");
    };
  ]

let first_right_line (fd : Diff_parser.file_diff) =
  List.find_map
    (fun (hunk : Diff_parser.hunk) ->
      match hunk.new_count > 0 with
      | true -> Some hunk.new_start
      | false -> None)
    fd.hunks

let added_lines (fd : Diff_parser.file_diff) =
  List.concat_map
    (fun (hunk : Diff_parser.hunk) ->
      let new_line = ref hunk.new_start in
      List.filter_map
        (fun line ->
          match line with
          | Diff_parser.Addition text ->
            let line_number = !new_line in
            incr new_line;
            Some (line_number, text)
          | Diff_parser.Context _ ->
            incr new_line;
            None
          | Diff_parser.Deletion _ -> None)
        hunk.lines)
    fd.hunks

let signal_of_line_rule ~path ~start_line ~end_line (rule : line_rule) =
  Security_types.
    {
      category = rule.category;
      vuln_class_hint = rule.vuln_class_hint;
      path;
      start_line;
      end_line;
      pattern = rule.pattern;
      rationale = rule.rationale;
    }

let signal_of_path_rule ~path ~start_line ~end_line (rule : path_rule) =
  Security_types.
    {
      category = rule.category;
      vuln_class_hint = rule.vuln_class_hint;
      path;
      start_line;
      end_line;
      pattern = rule.pattern;
      rationale = rule.rationale;
    }

let line_signals ~path (line_number, text) =
  let lowered = lower text in
  dangerous_api_rules @ security_control_rules @ stateful_rules
  |> List.filter (fun rule -> rule.matches lowered)
  |> List.map (signal_of_line_rule ~path ~start_line:line_number ~end_line:line_number)

let path_signals (fd : Diff_parser.file_diff) =
  match first_right_line fd with
  | None -> []
  | Some line ->
    risky_path_rules @ sensitive_file_rules
    |> List.filter (fun rule -> rule.matches_path fd.path)
    |> List.map (signal_of_path_rule ~path:fd.path ~start_line:line ~end_line:line)

let scan_file (fd : Diff_parser.file_diff) =
  path_signals fd @ List.concat_map (line_signals ~path:fd.path) (added_lines fd)

let scan diff = List.concat_map scan_file diff
