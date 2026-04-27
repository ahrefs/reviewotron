open Devkit
open Reviewotron_lib
open Cmdliner

let log = Log.from "reviewotron"

(* entrypoints *)

let run_action port secrets_path config_filename state_path logfile loglevel =
  Daemon.logfile := logfile;
  Option.may Log.set_loglevels loglevel;
  Log.reopen !Daemon.logfile;
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
        log#info "loaded secrets, starting HTTP server on port %d" port;
        Request_handler.start ~ctx ~port
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

(* flags *)

let port =
  let doc = "Port number for the HTTP server." in
  Arg.(value & opt int 8080 & info [ "p"; "port" ] ~docv:"PORT" ~doc)

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

(* commands *)

let run_cmd =
  let doc = "Start the HTTP webhook server." in
  let info = Cmd.info "run" ~doc in
  let term = Term.(const run_action $ port $ secrets $ config_filename $ state_path $ logfile $ loglevel) in
  Cmd.v info term

let check_cmd =
  let doc = "Parse and display a webhook payload without starting the server." in
  let info = Cmd.info "check" ~doc in
  let term = Term.(const check_action $ secrets $ config_filename $ state_path $ event_type $ payload_file) in
  Cmd.v info term

let default, info =
  let doc = "Reviewotron - an agentic code review bot" in
  Term.(ret (const (`Help (`Pager, None)))), Cmd.info "reviewotron" ~doc

let () =
  let cmds = [ run_cmd; check_cmd ] in
  let group = Cmd.group ~default info cmds in
  exit @@ Cmd.eval group
