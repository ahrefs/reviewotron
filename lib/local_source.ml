open Devkit

let log = Log.from "local_source"

type prepare_error =
  | Read_failed of string
  | Empty
  | Too_large of int
  | Too_many_files of int

let string_of_prepare_error = function
  | Read_failed msg -> msg
  | Empty -> "all files were filtered out by ignored path, file-regex, or generated-file filters; no code was reviewed"
  | Too_large total_lines -> Printf.sprintf "diff has %d lines, which exceeds the configured limit" total_lines
  | Too_many_files file_count -> Printf.sprintf "diff touches %d files, which exceeds the configured limit" file_count

let read_file path =
  Lwt.catch
    (fun () ->
      let%lwt contents = Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read in
      Lwt.return (Ok contents))
    (fun exn -> Lwt.return (Error (Printf.sprintf "failed to read %s: %s" path (Exn.str exn))))

let unsafe_path_component_reason = function
  | "" -> Some "empty path components are not allowed"
  | "." -> Some "current-directory path components are not allowed"
  | ".." -> Some "parent-directory path components are not allowed"
  | _ -> None

let unsafe_relative_path_reason path =
  match Filename.is_relative path with
  | false -> Some "absolute paths are not allowed"
  | true -> List.find_map unsafe_path_component_reason (String.split_on_char '/' path)

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.equal (String.sub value 0 prefix_len) prefix

let has_trailing_separator path =
  match String.length path with
  | 0 -> false
  | len -> String.equal (String.sub path (len - 1) 1) Filename.dir_sep

let with_trailing_separator path =
  match has_trailing_separator path with
  | true -> path
  | false -> path ^ Filename.dir_sep

let path_is_under_root ~root path = String.equal root path || has_prefix ~prefix:(with_trailing_separator root) path

let realpath path =
  match Unix.realpath path with
  | resolved -> Ok resolved
  | exception Unix.Unix_error (error, fn, arg) ->
    Error (Printf.sprintf "%s %s failed: %s" fn arg (Unix.error_message error))

let resolve_fetch_path ~root ~path =
  match unsafe_relative_path_reason path with
  | Some reason -> Error (Printf.sprintf "refusing to read unsafe local path %S: %s" path reason)
  | None ->
    let full_path = Filename.concat root path in
    (match realpath root with
    | Error msg -> Error msg
    | Ok root ->
    match Unix.realpath full_path with
    | exception Unix.Unix_error _ -> Ok None
    | resolved_path when path_is_under_root ~root resolved_path -> Ok (Some resolved_path)
    | resolved_path ->
      Error (Printf.sprintf "refusing to read local path outside root: %s resolves to %s" path resolved_path))

(* Drop binary/oversized blobs before they reach the agent prompt, the same
   guard the GitHub source applies. A dropped file reads as "unavailable". Both
   the worktree and revision fetchers end here so the two paths report dropped
   files identically. *)
let embeddable_or_dropped ~path contents =
  match Review_job.is_embeddable contents with
  | true -> Ok (Some contents)
  | false ->
    log#warn "skipping %s: not embeddable (binary or too large)" path;
    Ok None

let fetch_file_from_root ~root ~path =
  match resolve_fetch_path ~root ~path with
  | Error msg -> Lwt.return (Error msg)
  | Ok None -> Lwt.return (Ok None)
  | Ok (Some full_path) ->
  match%lwt read_file full_path with
  | Error msg -> Lwt.return (Error msg)
  | Ok contents -> Lwt.return (embeddable_or_dropped ~path contents)

let fetch_file_from_revision ~root ~revision ~path =
  match unsafe_relative_path_reason path with
  | Some reason -> Lwt.return (Error (Printf.sprintf "refusing to read unsafe local path %S: %s" path reason))
  | None ->
  (* A path absent from the revision (e.g. deleted by the commit) is
     "unavailable"; a path that resolves to a tree or any other real error is
     surfaced, matching [fetch_file_from_root]'s read-error contract. *)
  match Local_git.object_type ~root ~revision ~path with
  | Local_git.Missing -> Lwt.return (Ok None)
  | Local_git.Object "blob" ->
    let object_name = Printf.sprintf "%s:%s" revision path in
    (match Local_git.run_git_raw ~cwd:root [ "cat-file"; "blob"; object_name ] with
    | Error msg -> Lwt.return (Error (Printf.sprintf "failed to read %s: %s" path msg))
    | Ok contents -> Lwt.return (embeddable_or_dropped ~path contents))
  | Local_git.Object kind ->
    Lwt.return (Error (Printf.sprintf "failed to read %s: expected a file but found a %s" path kind))

let digest_change_key diff_text = Digest.(to_hex (string diff_text))

let prepare_diff ~config diff_text =
  match Review_engine.prepare_diff ~config diff_text with
  | Ok prepared -> Ok prepared
  | Error `Empty -> Error Empty
  | Error (`Too_large total_lines) -> Error (Too_large total_lines)
  | Error (`Too_many_files file_count) -> Error (Too_many_files file_count)

let prepare_review_from_text ~root ~repo_key ?change_key ?revision ~title ~description ~diff_text ~config () =
  match prepare_diff ~config diff_text with
  | Error error -> Lwt.return (Error error)
  | Ok { Review_engine.filtered_diff; filtered_text } ->
    let digest = digest_change_key filtered_text in
    let default_change_key, change_label, head_sha, fetch_file =
      match revision with
      | Some revision ->
        ( Printf.sprintf "commit/%s" revision,
          (match change_key with
          | Some key -> Printf.sprintf "local change %s" key
          | None -> Printf.sprintf "local commit %s" revision),
          revision,
          fetch_file_from_revision ~root ~revision )
      | None ->
        ( Printf.sprintf "diff/%s" digest,
          (match change_key with
          | Some key -> Printf.sprintf "local change %s" key
          | None -> Printf.sprintf "local diff %s" (Review_job.short_display_id digest)),
          digest,
          fetch_file_from_root ~root )
    in
    let change_key = CCOption.get_or ~default:default_change_key change_key in
    (* Preload the deep reviewer with the same key files a GitHub-source review
       gets (added/modified, first few), read from the local repo at the
       reviewed revision via [fetch_file] — no network. Selection and drop
       policy are shared with the GitHub source (see {!Review_job.select_key_files}). *)
    let log_prefix = Review_job.log_context_for ~repo_key ~change_label ~head_sha ^ " " in
    let%lwt file_contents = Review_job.select_key_files ~log_context:log_prefix ~diff:filtered_diff ~fetch:fetch_file () in
    log#info "%sembedded %d key file(s)" log_prefix (List.length file_contents);
    let job =
      Review_job.
        {
          repo_key;
          change_key;
          change_label;
          title;
          description;
          head_sha;
          diff_text = filtered_text;
          filtered_diff;
          config;
          file_contents;
          fetch_file;
          trigger = Local;
          source_kind = Local;
        }
    in
    Lwt.return (Ok job)

let prepare_review ~root ~repo_key ?change_key ?revision ~title ~description ~diff_path ~config () =
  match%lwt read_file diff_path with
  | Error msg -> Lwt.return (Error (Read_failed msg))
  | Ok diff_text ->
    prepare_review_from_text ~root ~repo_key ?change_key ?revision ~title ~description ~diff_text ~config ()
