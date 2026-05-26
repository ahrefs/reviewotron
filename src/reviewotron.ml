open Devkit
open Reviewotron_lib
open Cmdliner

let log = Log.from "reviewotron"

(* entrypoints *)

let setup_logging logfile loglevel =
  Daemon.logfile := logfile;
  Option.may Log.set_loglevels loglevel;
  Log.reopen !Daemon.logfile

let run_action addr port secrets_path config_filename state_path logfile loglevel =
  setup_logging logfile loglevel;
  Signal.setup_lwt ();
  Daemon.install_signal_handlers ();
  Mirage_crypto_rng_unix.use_default ();
  Lwt_main.run
    begin
      log#info "reviewotron starting";
      match Context.create ~secrets_filepath:secrets_path ?config_filename ?state_filepath:state_path () with
      | Error e ->
        log#error "failed to initialize: %s" e;
        Lwt.return_unit
      | Ok ctx ->
        log#info "loaded secrets, starting HTTP server on %s:%d" addr port;
        Request_handler.start ~ctx ~addr ~port
    end

let check_action secrets_path config_filename state_path event_type payload_file =
  log#info "check mode: event_type=%s, payload=%s" event_type payload_file;
  match Context.create ~secrets_filepath:secrets_path ?config_filename ?state_filepath:state_path () with
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
        | Github.Unknown kind -> Printf.printf "Event: %s (unhandled)\n" kind)
      end)

type output_format = Markdown

let read_text_file path =
  match Std.input_file ~bin:true path with
  | contents -> Ok contents
  | exception exn -> Error (Printf.sprintf "failed to read %s: %s" path (Exn.str exn))

let read_description_file = function
  | None -> Ok ""
  | Some path -> read_text_file path

let review_diff_action secrets_path config_filename state_path logfile loglevel root repo_key change_key title
  description_file diff_file output =
  setup_logging logfile loglevel;
  Mirage_crypto_rng_unix.use_default ();
  match Context.create ~secrets_filepath:secrets_path ?config_filename ?state_filepath:state_path () with
  | Error e -> log#error "failed to initialize: %s" e
  | Ok ctx ->
  match read_description_file description_file with
  | Error msg -> log#error "%s" msg
  | Ok description ->
    let module Review = Local_review.Make (Api_remote.Agent_runner) in
    let config = Context.get_config ctx ~repo_url:repo_key in
    let result =
      Lwt_main.run
        (Review.review_diff ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_path:diff_file ~config ())
    in
    (match result, output with
    | Error msg, Markdown -> log#error "%s" msg
    | Ok markdown, Markdown -> Printf.printf "%s\n" markdown)

(* flags *)

let addr =
  let doc = "IP address that the HTTP server should bind to." in
  Arg.(value & opt string "127.0.0.1" & info [ "a"; "addr" ] ~docv:"ADDR" ~doc)

let port =
  let doc = "Port number for the HTTP server." in
  Arg.(value & opt int 1338 & info [ "p"; "port" ] ~docv:"PORT" ~doc)

let secrets =
  let doc = "Path to secrets.json file." in
  Arg.(value & opt file "secrets.json" & info [ "secrets" ] ~docv:"SECRETS" ~doc)

let config_filename =
  let doc = "Config filename to look for in repos (default: .reviewotron.json)." in
  Arg.(value & opt (some string) None & info [ "config-filename" ] ~docv:"FILENAME" ~doc)

let state_path =
  let doc = "Path to state file for persistence (default: in-memory only)." in
  Arg.(value & opt (some string) None & info [ "state" ] ~docv:"STATE" ~doc)

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
  let doc = "Repository root used for local file-content lookups." in
  Arg.(value & opt dir "." & info [ "root" ] ~docv:"ROOT" ~doc)

let repo_key =
  let doc = "Stable repository key for local review state, memory paths, and logs." in
  Arg.(value & opt string "local" & info [ "repo-key" ] ~docv:"REPO_KEY" ~doc)

let change_key =
  let doc = "Stable change key for this local diff. Defaults to a digest of the diff." in
  Arg.(value & opt (some string) None & info [ "change-key" ] ~docv:"CHANGE_KEY" ~doc)

let title =
  let doc = "Title passed to the review agents." in
  Arg.(value & opt string "Local change" & info [ "title" ] ~docv:"TITLE" ~doc)

let description_file =
  let doc = "Optional markdown/text file whose contents are passed as the review description." in
  Arg.(value & opt (some file) None & info [ "description-file" ] ~docv:"DESCRIPTION" ~doc)

let diff_file =
  let doc = "Path to a unified diff file to review." in
  Arg.(required & opt (some file) None & info [ "diff" ] ~docv:"DIFF" ~doc)

let output_format =
  let formats = [ "markdown", Markdown ] in
  let doc = "Output format. Supported value: $(b,markdown)." in
  Arg.(value & opt (enum formats) Markdown & info [ "output" ] ~docv:"FORMAT" ~doc)

(* commands *)

let run_cmd =
  let doc = "Start the HTTP webhook server." in
  let info = Cmd.info "run" ~doc in
  let term = Term.(const run_action $ addr $ port $ secrets $ config_filename $ state_path $ logfile $ loglevel) in
  Cmd.v info term

let check_cmd =
  let doc = "Parse and display a webhook payload without starting the server." in
  let info = Cmd.info "check" ~doc in
  let term = Term.(const check_action $ secrets $ config_filename $ state_path $ event_type $ payload_file) in
  Cmd.v info term

let review_diff_cmd =
  let doc = "Review a local unified diff and print markdown." in
  let info = Cmd.info "review-diff" ~doc in
  let term =
    Term.(
      const review_diff_action
      $ secrets
      $ config_filename
      $ state_path
      $ logfile
      $ loglevel
      $ local_root
      $ repo_key
      $ change_key
      $ title
      $ description_file
      $ diff_file
      $ output_format)
  in
  Cmd.v info term

let default, info =
  let doc = "Reviewotron - an agentic code review bot" in
  Term.(ret (const (`Help (`Pager, None)))), Cmd.info "reviewotron" ~doc

let () =
  let cmds = [ run_cmd; check_cmd; review_diff_cmd ] in
  let group = Cmd.group ~default info cmds in
  exit @@ Cmd.eval group
