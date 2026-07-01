open Devkit
open Reviewotron_lib
open Cmdliner

let log = Log.from "reviewotron"

module Review = Local_review.Make (Api_remote.Agent_runner)
module Feedback_collector_remote = Feedback_collector.Make (Api_remote.Github)

(* entrypoints *)

let setup_logging logfile loglevel =
  Daemon.logfile := logfile;
  Option.may Log.set_loglevels loglevel;
  Log.reopen !Daemon.logfile

let validate_poll_interval ~command ~allow_zero poll_interval_seconds =
  match poll_interval_seconds < 0, Int.equal poll_interval_seconds 0 && not allow_zero with
  | true, _ -> Error (Printf.sprintf "--poll-interval-seconds must be non-negative for %s" command)
  | false, true -> Error (Printf.sprintf "--poll-interval-seconds must be positive for %s" command)
  | false, false -> Ok ()

let feedback_poll_loop ~ctx ~store ~poll_interval_seconds =
  let rec loop () =
    Lwt.catch
      (fun () ->
        let%lwt () =
          Feedback_collector_remote.collect ~poll_interval_seconds ~ctx ~store ~now:(Ptime_clock.now ()) ()
        in
        let%lwt () = Lwt_unix.sleep (float_of_int poll_interval_seconds) in
        loop ())
      (function
        | Lwt.Canceled -> Lwt.fail Lwt.Canceled
        | exn ->
          log#error "feedback polling failed: %s" (Exn.str exn);
          let%lwt () = Lwt_unix.sleep (float_of_int poll_interval_seconds) in
          loop ())
  in
  loop ()

let start_server_with_feedback_polling ~ctx ~addr ~port ~poll_interval_seconds =
  let server = Request_handler.start ~ctx ~addr ~port in
  match Context.feedback_store ctx with
  | None ->
    log#info "feedback polling disabled: start with --state to enable feedback collection";
    server
  | Some store ->
    let paths = Feedback_store.paths store in
    let target_count = List.length (Feedback_store.data store).targets in
    log#info "feedback polling enabled every %d seconds (targets=%d targets_file=%s events_file=%s evidence_root=%s)"
      poll_interval_seconds target_count paths.targets paths.events paths.evidence_root;
    let poller = feedback_poll_loop ~ctx ~store ~poll_interval_seconds in
    Lwt.finalize
      (fun () -> server)
      (fun () ->
        Lwt.cancel poller;
        Lwt.return_unit)

let run_action addr port secrets_path config_filename state_path feedback_dir poll_interval_seconds logfile loglevel =
  setup_logging logfile loglevel;
  Signal.setup_lwt ();
  Daemon.install_signal_handlers ();
  Mirage_crypto_rng_unix.use_default ();
  Lwt_main.run
    begin
      log#info "reviewotron starting";
      match validate_poll_interval ~command:"run" ~allow_zero:false poll_interval_seconds with
      | Error e ->
        log#error "%s" e;
        Lwt.return_unit
      | Ok () ->
      match
        Context.create ~secrets_filepath:secrets_path ?config_filename ?state_filepath:state_path ?feedback_dir ()
      with
      | Error e ->
        log#error "failed to initialize: %s" e;
        Lwt.return_unit
      | Ok ctx ->
        log#info "loaded secrets, starting HTTP server on %s:%d" addr port;
        start_server_with_feedback_polling ~ctx ~addr ~port ~poll_interval_seconds
    end

let check_action secrets_path config_filename state_path feedback_dir event_type payload_file =
  log#info "check mode: event_type=%s, payload=%s" event_type payload_file;
  match
    Context.create ~secrets_filepath:secrets_path ?config_filename ?state_filepath:state_path ?feedback_dir
      ~require_repos:false ()
  with
  | Error e ->
    log#error "failed to initialize: %s" e;
    ()
  | Ok _ctx ->
    let body =
      match Std.input_file ~bin:true payload_file with
      | contents when String.length contents > 0 -> Ok contents
      | _ -> Error "payload file is empty"
      | exception exn -> Error (Printf.sprintf "failed to read payload file %s: %s" payload_file (Exn.str exn))
    in
    (match body with
    | Error msg -> log#error "%s" msg
    | Ok body ->
      begin match Github.parse_event ~event_type ~body with
      | Error msg -> log#error "parse error: %s" msg
      | Ok event ->
        let _repo_url = Github.repo_url_of_event event in
        (match event with
        | Github.Pull_request n ->
          Printf.printf "Event: pull_request\n";
          Printf.printf "Action: %s\n" n.action;
          Printf.printf "Repository: %s\n" n.repository.full_name;
          Printf.printf "PR #%d: %s\n" n.pull_request.number n.pull_request.title;
          Printf.printf "Author: %s\n" n.pull_request.user.login;
          Printf.printf "State: %s\n" n.pull_request.state;
          Printf.printf "Changes: +%d -%d (%d files)\n" n.pull_request.additions n.pull_request.deletions
            n.pull_request.changed_files;
          Printf.printf "Head: %s (%s)\n" n.pull_request.head.sha n.pull_request.head.ref_;
          Printf.printf "Base: %s (%s)\n" n.pull_request.base.sha n.pull_request.base.ref_
        | Github.Push n ->
          Printf.printf "Event: push\n";
          Printf.printf "Repository: %s\n" n.repository.full_name;
          Printf.printf "Ref: %s\n" n.ref_;
          Printf.printf "Commits: %d\n" (List.length n.commits);
          Printf.printf "Compare: %s\n" n.compare;
          Printf.printf "Pusher: %s\n" n.pusher.name;
          List.iter
            (fun (c : Github_types.commit) ->
              let short_sha = String.sub c.id 0 (min 8 (String.length c.id)) in
              Printf.printf "  %s %s\n" short_sha (Stre.shorten 72 c.message))
            n.commits
        | Github.Issue_comment n ->
          Printf.printf "Event: issue_comment\n";
          Printf.printf "Action: %s\n" n.action;
          Printf.printf "Repository: %s\n" n.repository.full_name;
          Printf.printf "Issue: #%d %s (state=%s)\n" n.issue.number n.issue.title n.issue.state;
          Printf.printf "Is PR: %b\n" (Option.is_some n.issue.pull_request);
          Printf.printf "Sender: %s\n" n.sender.login;
          Printf.printf "Body: %s\n" (Stre.shorten 200 n.comment.body)
        | Github.Pull_request_review n ->
          Printf.printf "Event: pull_request_review\n";
          Printf.printf "Action: %s\n" n.action;
          Printf.printf "Repository: %s\n" n.repository.full_name;
          Printf.printf "PR #%d: %s\n" n.pull_request.number n.pull_request.title;
          Printf.printf "Sender: %s\n" n.sender.login
        | Github.Pull_request_review_comment n ->
          Printf.printf "Event: pull_request_review_comment\n";
          Printf.printf "Action: %s\n" n.action;
          Printf.printf "Repository: %s\n" n.repository.full_name;
          Printf.printf "PR #%d: %s\n" n.pull_request.number n.pull_request.title;
          Printf.printf "Sender: %s\n" n.sender.login;
          Printf.printf "Body: %s\n" (Stre.shorten 200 n.comment.body)
        | Github.Unknown kind -> Printf.printf "Event: %s (unhandled)\n" kind)
      end)

let collect_feedback_action secrets_path state_path feedback_dir poll_interval_seconds logfile loglevel =
  setup_logging logfile loglevel;
  Mirage_crypto_rng_unix.use_default ();
  let fail fmt =
    Printf.ksprintf
      (fun msg ->
        log#error "%s" msg;
        exit 1)
      fmt
  in
  Lwt_main.run
    begin match Context.create ~secrets_filepath:secrets_path ~state_filepath:state_path ?feedback_dir () with
    | Error e -> fail "failed to initialize feedback collector: %s" e
    | Ok ctx ->
    match Context.feedback_store ctx with
    | None -> fail "feedback collector requires --state"
    | Some store ->
    match validate_poll_interval ~command:"collect-feedback" ~allow_zero:true poll_interval_seconds with
    | Error e -> fail "%s" e
    | Ok () -> Feedback_collector_remote.collect ~poll_interval_seconds ~ctx ~store ~now:(Ptime_clock.now ()) ()
    end

type output_format =
  | Markdown
  | Json

let feedback_report_action state_path feedback_dir output sentiment review_batch_id pr_number limit brief =
  let paths = Feedback_store.derive_paths ?feedback_dir ~state_filepath:state_path () in
  match limit with
  | Some limit when Int.compare limit 1 < 0 ->
    Printf.eprintf "feedback-report --limit must be greater than 0\n";
    exit 1
  | Some _ | None ->
  match Feedback_report.load paths with
  | Error msg ->
    Printf.eprintf "failed to load feedback report: %s\n" msg;
    exit 1
  | Ok report ->
    let filter : Feedback_report.filter = { sentiment; review_batch_id; pr_number; limit } in
    let report = Feedback_report.apply_filter filter report in
    let rendered =
      match output with
      | Markdown -> Feedback_report.render_markdown ~include_messages:(not brief) report
      | Json -> Yojson.Basic.pretty_to_string (Feedback_report.to_json report)
    in
    Printf.printf "%s\n" rendered

(* local review (file / folder / diff) — the agent-facing path *)

let render_review_output output report =
  match output with
  | Markdown -> Local_sink.render_markdown report
  | Json -> Local_sink.render_json report

let run_local_review f =
  try Lwt_main.run (f ()) with exn -> Error (Printf.sprintf "local review failed: %s" (Exn.str exn))

let log_local_review_error msg =
  match Local_review.is_already_reviewed_message msg with
  | true -> log#info "%s" msg
  | false -> log#error "%s" msg

(* Print the review on success; on failure emit a JSON error envelope (JSON
   mode) or log it (markdown mode). Exit non-zero on a genuine failure so a
   calling agent can branch on the exit code; an already-reviewed skip is not a
   failure. *)
let emit_local_result ~output result =
  match result with
  | Ok report -> Printf.printf "%s\n" (render_review_output output report)
  | Error msg ->
    (match output with
    | Json -> Printf.printf "%s\n" (Local_sink.render_error msg)
    | Markdown -> log_local_review_error msg);
    (match Local_review.is_already_reviewed_message msg with
    | true -> ()
    | false -> exit 1)

let read_text_file path =
  match Std.input_file ~bin:true path with
  | contents -> Ok contents
  | exception exn -> Error (Printf.sprintf "failed to read %s: %s" path (Exn.str exn))

let read_description_file = function
  | None -> Ok ""
  | Some path -> read_text_file path

let read_stdin () =
  set_binary_mode_in stdin true;
  let buffer = Buffer.create 65536 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    match input stdin chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | n ->
      Buffer.add_subbytes buffer chunk 0 n;
      loop ()
  in
  loop ()

let resolve_local_root = function
  | Some root -> Local_git.normalize_path root
  | None -> Local_git.default_root ~cwd:(Sys.getcwd ())

let resolve_repo_key ~root = function
  | Some repo_key -> repo_key
  | None -> Local_git.default_repo_key ~root

(* Single definition of "blank key" lives in [Llm_provider]; alias it here so
   the CLI key-precedence chains and [Llm_provider.resolve] agree on what counts
   as a usable key. *)
let nonempty = Llm_provider.nonempty

let env_api_key () = Stdlib.Option.bind (Sys.getenv_opt "ANTHROPIC_API_KEY") nonempty
let env_openrouter_key () = Stdlib.Option.bind (Sys.getenv_opt "OPENROUTER_API_KEY") nonempty

(* A secrets file is optional for local review: it only matters when the agent
   wants the API key (and any Slack/repo settings) to come from disk instead of
   the environment. A missing or unparseable file is not fatal — the key may
   still come from the flag or the environment. *)
let load_optional_secrets = function
  | Some path when Sys.file_exists path ->
    (match Context.load_secrets_file ~filepath:path with
    | Ok secrets -> Some secrets
    | Error msg ->
      log#warn "ignoring secrets file %s: %s" path msg;
      None)
  | Some _ | None -> None

(* Build a context for local review without requiring any file on disk.
   Each key is resolved independently — Anthropic from --anthropic-api-key, then
   ANTHROPIC_API_KEY, then a secrets file; OpenRouter from --openrouter-api-key,
   then OPENROUTER_API_KEY, then a secrets file. Provider selection is then
   credential-driven (see {!Llm_provider.resolve}). Repos and Slack token are
   taken from the secrets file when one is present, and are otherwise empty
   (local review needs neither). We fail only when BOTH keys are absent. *)
let build_local_context ~secrets_path ~api_key_flag ~openrouter_api_key_flag ~config_filename ~state_path =
  let file_secrets = load_optional_secrets secrets_path in
  let anthropic_api_key =
    List.find_map Fun.id
      [
        Stdlib.Option.bind api_key_flag nonempty;
        env_api_key ();
        Stdlib.Option.bind file_secrets (fun (s : Config_types.secrets) ->
          Stdlib.Option.bind s.anthropic_api_key nonempty);
      ]
  in
  let openrouter_api_key =
    List.find_map Fun.id
      [
        Stdlib.Option.bind openrouter_api_key_flag nonempty;
        env_openrouter_key ();
        Stdlib.Option.bind file_secrets (fun (s : Config_types.secrets) ->
          Stdlib.Option.bind s.openrouter_api_key nonempty);
      ]
  in
  match anthropic_api_key, openrouter_api_key with
  | None, None ->
    Error
      "no LLM API key found; set OPENROUTER_API_KEY (preferred) or ANTHROPIC_API_KEY, pass --openrouter-api-key or \
       --anthropic-api-key, or provide --secrets with an openrouter_api_key or anthropic_api_key field"
  | _ ->
    let repos =
      match file_secrets with
      | Some s -> s.repos
      | None -> []
    in
    let slack_access_token = Stdlib.Option.bind file_secrets (fun (s : Config_types.secrets) -> s.slack_access_token) in
    let secrets : Config_types.secrets = { repos; anthropic_api_key; openrouter_api_key; slack_access_token } in
    let state =
      match state_path with
      | Some path -> State.load ~filepath:path
      | None -> State.create ()
    in
    Ok (Context.make ~secrets ?config_filename ~state ())

(* Config precedence: inline --config, then a config file in the root, then
   built-in defaults. *)
let resolve_local_config ~ctx ~root ~inline_config =
  match inline_config with
  | Some json -> Context.parse_config json
  | None -> Context.load_local_config ~root ~config_filename:(Context.config_filename ctx)

(* Local review runs the security pipeline by default (opt-out via --no-security),
   unlike the webhook path where it is off by default. The flag owns the on/off
   decision; --config still controls the security details (vuln_classes, model
   tiers, thresholds). *)
let apply_local_plugin_defaults ~no_security (config : Config_types.config) =
  let security = { config.review_plugins.security with enabled = not no_security } in
  { config with review_plugins = { config.review_plugins with security } }

let resolve_diff_source ~root ~base = function
  | Some "-" -> Ok (`Text (read_stdin ()), "Review diff from stdin")
  | Some path -> Ok (`File path, Local_git.title_for_diff_file path)
  | None ->
  match Local_git.infer_base ~root ~explicit:base with
  | Error msg -> Error msg
  | Ok base ->
  match Local_git.diff_against_base ~root ~base with
  | Error msg -> Error msg
  | Ok diff_text -> Ok (`Text diff_text, Local_git.title_for_base base)

let review_diff_action secrets_path api_key_flag openrouter_api_key_flag config_filename state_path logfile loglevel
  root repo_key change_key title base description_file diff_arg inline_config no_security output =
  setup_logging logfile loglevel;
  Mirage_crypto_rng_unix.use_default ();
  let ( let* ) = Result.bind in
  let result =
    let* ctx = build_local_context ~secrets_path ~api_key_flag ~openrouter_api_key_flag ~config_filename ~state_path in
    let root = resolve_local_root root in
    let repo_key = resolve_repo_key ~root repo_key in
    let* config = resolve_local_config ~ctx ~root ~inline_config in
    let config = apply_local_plugin_defaults ~no_security config in
    Context.set_config ctx ~repo_key config;
    let* diff_source, default_title = resolve_diff_source ~root ~base diff_arg in
    let* description = read_description_file description_file in
    let title = CCOption.get_or ~default:default_title title in
    match diff_source with
    | `File diff_path ->
      run_local_review (fun () ->
        Review.review_diff_report ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_path ~config ())
    | `Text diff_text ->
      run_local_review (fun () ->
        Review.review_diff_text_report ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_text ~config ())
  in
  emit_local_result ~output result

let review_path_action secrets_path api_key_flag openrouter_api_key_flag config_filename state_path logfile loglevel
  repo_key change_key title inline_config no_security output path =
  setup_logging logfile loglevel;
  Mirage_crypto_rng_unix.use_default ();
  let ( let* ) = Result.bind in
  let result =
    let* ctx = build_local_context ~secrets_path ~api_key_flag ~openrouter_api_key_flag ~config_filename ~state_path in
    let* ingest = Local_path.ingest path in
    let root = ingest.Local_path.root in
    let repo_key = resolve_repo_key ~root repo_key in
    let* config = resolve_local_config ~ctx ~root ~inline_config in
    let config = apply_local_plugin_defaults ~no_security config in
    Context.set_config ctx ~repo_key config;
    log#info "reviewing %d file(s) under %s" ingest.Local_path.file_count root;
    let title = CCOption.get_or ~default:ingest.Local_path.title title in
    run_local_review (fun () ->
      Review.review_diff_text_report ~ctx ~root ~repo_key ?change_key ~title ~description:""
        ~diff_text:ingest.Local_path.diff_text ~config ())
  in
  emit_local_result ~output result

let config_help_action () = Printf.printf "%s\n" (Config_types.config_help_json ())

(* flags *)

let addr =
  let doc = "IP address that the HTTP server should bind to." in
  Arg.(value & opt string "127.0.0.1" & info [ "a"; "addr" ] ~docv:"ADDR" ~doc)

let port =
  let doc = "Port number for the HTTP server." in
  Arg.(value & opt int 1338 & info [ "p"; "port" ] ~docv:"PORT" ~doc)

let secrets =
  let doc = "Path to secrets.json file (default: ./secrets.json)." in
  Arg.(value & opt file "secrets.json" & info [ "secrets" ] ~docv:"SECRETS" ~doc)

let local_secrets =
  let doc =
    "Optional path to a secrets.json file. When omitted or absent, the API key is taken from --openrouter-api-key / \
     --anthropic-api-key or the OPENROUTER_API_KEY / ANTHROPIC_API_KEY environment variables."
  in
  Arg.(value & opt (some string) None & info [ "secrets" ] ~docv:"SECRETS" ~doc)

let anthropic_api_key =
  let doc = "Anthropic API key. Overrides the ANTHROPIC_API_KEY environment variable and any secrets file." in
  Arg.(value & opt (some string) None & info [ "anthropic-api-key" ] ~docv:"KEY" ~doc)

let openrouter_api_key =
  let doc =
    "OpenRouter API key (preferred when set). Overrides the OPENROUTER_API_KEY environment variable and any secrets \
     file."
  in
  Arg.(value & opt (some string) None & info [ "openrouter-api-key" ] ~docv:"KEY" ~doc)

let config_filename =
  let doc = "Config filename to look for in repos (default: .reviewotron.json)." in
  Arg.(value & opt (some string) None & info [ "config-filename" ] ~docv:"FILENAME" ~doc)

let inline_config =
  let doc =
    "Inline review configuration as a JSON string (same schema as the config file). Takes precedence over any config \
     file."
  in
  Arg.(value & opt (some string) None & info [ "config" ] ~docv:"JSON" ~doc)

let no_security =
  let doc =
    "Disable the security review plugin. In local review-diff / review-path mode the security pipeline runs by \
     default; pass this to turn it off."
  in
  Arg.(value & flag & info [ "no-security" ] ~doc)

let state_path =
  let doc = "Path to state file for persistence (default: in-memory only)." in
  Arg.(value & opt (some string) None & info [ "state" ] ~docv:"STATE" ~doc)

let required_state_path =
  let doc = "Path to state file. Feedback files are loaded from --feedback-dir, or sibling paths next to this file." in
  Arg.(required & opt (some string) None & info [ "state" ] ~docv:"STATE" ~doc)

let feedback_dir =
  let doc =
    "Directory for feedback targets, events, and evidence bundles. Defaults to sibling paths next to --state."
  in
  Arg.(value & opt (some string) None & info [ "feedback-dir" ] ~docv:"DIR" ~doc)

let feedback_poll_interval_seconds =
  let doc =
    "Minimum seconds between reaction polls for the same feedback target. In run mode this is also the background \
     poller cadence and must be positive. In collect-feedback mode, 0 forces a recheck on every command run."
  in
  Arg.(value & opt int (60 * 60) & info [ "poll-interval-seconds" ] ~docv:"SECONDS" ~doc)

let logfile =
  let doc = "Log file path (output to stderr if absent)." in
  Arg.(value & opt (some string) None & info [ "logfile" ] ~docv:"LOGFILE" ~doc)

let loglevel =
  let doc = "Log level, e.g. debug, info, warn, error." in
  Arg.(value & opt (some string) None & info [ "loglevel" ] ~docv:"LOGLEVEL" ~doc)

let event_type =
  let doc = "GitHub event type (e.g. pull_request, push)." in
  Arg.(required & opt (some string) None & info [ "event-type" ] ~docv:"EVENT_TYPE" ~doc)

let payload_file =
  let doc = "Path to a JSON file containing a GitHub webhook payload." in
  Arg.(required & opt (some file) None & info [ "payload" ] ~docv:"PAYLOAD" ~doc)

let local_root =
  let doc = "Repository root used for local file-content lookups. Defaults to the Git worktree root, then cwd." in
  Arg.(value & opt (some dir) None & info [ "root" ] ~docv:"ROOT" ~doc)

let repo_key =
  let doc = "Stable repository key for local review state, memory paths, and logs. Defaults to local:<root>." in
  Arg.(value & opt (some string) None & info [ "repo-key" ] ~docv:"REPO_KEY" ~doc)

let change_key =
  let doc = "Stable change key for this local diff. Defaults to a digest of the diff." in
  Arg.(value & opt (some string) None & info [ "change-key" ] ~docv:"CHANGE_KEY" ~doc)

let title =
  let doc = "Title passed to the review agents. Defaults to the inferred base, diff file, or reviewed path." in
  Arg.(value & opt (some string) None & info [ "title" ] ~docv:"TITLE" ~doc)

let base_ref =
  let doc =
    "Base ref for default Git diff generation. When omitted, reviewotron tries origin/HEAD, origin/main, \
     origin/master, and the current branch upstream remote."
  in
  Arg.(value & opt (some string) None & info [ "base" ] ~docv:"BASE" ~doc)

let description_file =
  let doc = "Optional markdown/text file whose contents are passed as the review description." in
  Arg.(value & opt (some file) None & info [ "description-file" ] ~docv:"DESCRIPTION" ~doc)

let diff_arg =
  let doc =
    "Unified diff to review: a path to a diff file, or \"-\" to read the diff from stdin. Defaults to a Git diff \
     against the inferred base ref."
  in
  Arg.(value & opt (some string) None & info [ "diff" ] ~docv:"DIFF" ~doc)

let path_arg =
  let doc = "File or directory to review. Every file is treated as newly added; directories are walked recursively." in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH" ~doc)

let output_format =
  let formats = [ "markdown", Markdown; "json", Json ] in
  let doc = "Output format. Supported values: $(b,markdown), $(b,json)." in
  Arg.(value & opt (enum formats) Markdown & info [ "output" ] ~docv:"FORMAT" ~doc)

let feedback_sentiment =
  let sentiments =
    [
      "all", Feedback_report.All;
      "reacted", Feedback_report.Reacted;
      "positive", Feedback_report.Positive;
      "negative", Feedback_report.Negative;
      "mixed", Feedback_report.Mixed;
      "unreacted", Feedback_report.Unreacted;
    ]
  in
  let doc =
    "Filter feedback by sentiment: $(b,all), $(b,reacted), $(b,positive), $(b,negative), $(b,mixed), or $(b,unreacted)."
  in
  Arg.(value & opt (enum sentiments) Feedback_report.All & info [ "sentiment" ] ~docv:"SENTIMENT" ~doc)

let feedback_review_batch_id =
  let doc = "Limit feedback-report output to one review batch ID." in
  Arg.(value & opt (some string) None & info [ "review-batch-id" ] ~docv:"REVIEW_BATCH_ID" ~doc)

let feedback_pr_number =
  let doc = "Limit feedback-report output to one pull request number." in
  Arg.(value & opt (some int) None & info [ "pr" ] ~docv:"PR_NUMBER" ~doc)

let feedback_limit =
  let doc = "Limit feedback-report output to the first N matching feedback targets." in
  Arg.(value & opt (some int) None & info [ "limit" ] ~docv:"N" ~doc)

let feedback_brief =
  let doc = "Omit finding message snippets from markdown feedback-report output." in
  Arg.(value & flag & info [ "brief" ] ~doc)

(* commands *)

let run_cmd =
  let doc = "Start the HTTP webhook server." in
  let info = Cmd.info "run" ~doc in
  let term =
    Term.(
      const run_action
      $ addr
      $ port
      $ secrets
      $ config_filename
      $ state_path
      $ feedback_dir
      $ feedback_poll_interval_seconds
      $ logfile
      $ loglevel)
  in
  Cmd.v info term

let check_cmd =
  let doc = "Parse and display a webhook payload without starting the server." in
  let info = Cmd.info "check" ~doc in
  let term =
    Term.(const check_action $ secrets $ config_filename $ state_path $ feedback_dir $ event_type $ payload_file)
  in
  Cmd.v info term

let review_diff_cmd =
  let doc = "Review a unified diff (file, stdin, or Git working tree) and print markdown or JSON." in
  let info = Cmd.info "review-diff" ~doc in
  let term =
    Term.(
      const review_diff_action
      $ local_secrets
      $ anthropic_api_key
      $ openrouter_api_key
      $ config_filename
      $ state_path
      $ logfile
      $ loglevel
      $ local_root
      $ repo_key
      $ change_key
      $ title
      $ base_ref
      $ description_file
      $ diff_arg
      $ inline_config
      $ no_security
      $ output_format)
  in
  Cmd.v info term

let review_path_cmd =
  let doc = "Review a file or directory (treating every file as newly added) and print markdown or JSON." in
  let info = Cmd.info "review-path" ~doc in
  let term =
    Term.(
      const review_path_action
      $ local_secrets
      $ anthropic_api_key
      $ openrouter_api_key
      $ config_filename
      $ state_path
      $ logfile
      $ loglevel
      $ repo_key
      $ change_key
      $ title
      $ inline_config
      $ no_security
      $ output_format
      $ path_arg)
  in
  Cmd.v info term

let config_help_cmd =
  let doc = "Print the review configuration JSON Schema (field names, types, enums, descriptions)." in
  let info = Cmd.info "config-help" ~doc in
  Cmd.v info Term.(const config_help_action $ const ())

let collect_feedback_cmd =
  let doc = "Poll GitHub reactions for stored Reviewotron feedback targets." in
  let info = Cmd.info "collect-feedback" ~doc in
  let term =
    Term.(
      const collect_feedback_action
      $ secrets
      $ required_state_path
      $ feedback_dir
      $ feedback_poll_interval_seconds
      $ logfile
      $ loglevel)
  in
  Cmd.v info term

let feedback_report_cmd =
  let doc = "Summarize collected Reviewotron feedback targets and evidence bundles." in
  let info = Cmd.info "feedback-report" ~doc in
  let term =
    Term.(
      const feedback_report_action
      $ required_state_path
      $ feedback_dir
      $ output_format
      $ feedback_sentiment
      $ feedback_review_batch_id
      $ feedback_pr_number
      $ feedback_limit
      $ feedback_brief)
  in
  Cmd.v info term

let default, info =
  let doc = "Reviewotron - an agentic code review bot" in
  Term.(ret (const (`Help (`Pager, None)))), Cmd.info "reviewotron" ~doc

let () =
  let cmds =
    [ run_cmd; check_cmd; review_diff_cmd; review_path_cmd; collect_feedback_cmd; feedback_report_cmd; config_help_cmd ]
  in
  let group = Cmd.group ~default info cmds in
  exit @@ Cmd.eval group
