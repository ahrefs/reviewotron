open Devkit

type prepare_error =
  | Read_failed of string
  | Empty
  | Too_large of int

type prepared_review = {
  job : Review_job.t;
  filtered_diff : Diff_parser.file_diff list;
}

let string_of_prepare_error = function
  | Read_failed msg -> msg
  | Empty -> "all files were filtered out"
  | Too_large total_lines -> Printf.sprintf "diff has %d lines, which exceeds the configured limit" total_lines

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

let fetch_file_from_root ~root ~path =
  match resolve_fetch_path ~root ~path with
  | Error msg -> Lwt.return (Error msg)
  | Ok None -> Lwt.return (Ok None)
  | Ok (Some full_path) ->
  match%lwt read_file full_path with
  | Ok contents -> Lwt.return (Ok (Some contents))
  | Error msg -> Lwt.return (Error msg)

let digest_change_key diff_text = Digest.(to_hex (string diff_text))

let prepare_diff ~config diff_text =
  match Review_engine.prepare_diff ~config diff_text with
  | Ok prepared -> Ok prepared
  | Error `Empty -> Error Empty
  | Error (`Too_large total_lines) -> Error (Too_large total_lines)

let prepare_review_from_text ~root ~repo_key ?change_key ~title ~description ~diff_text ~config () =
  match prepare_diff ~config diff_text with
  | Error error -> Lwt.return (Error error)
  | Ok (filtered_diff, filtered_text) ->
    let digest = digest_change_key diff_text in
    let change_key = CCOption.get_or ~default:(Printf.sprintf "diff/%s" digest) change_key in
    let fetch_file = fetch_file_from_root ~root in
    let job =
      Review_job.
        {
          repo_key;
          change_key;
          title;
          description;
          head_sha = digest;
          diff_text = filtered_text;
          config;
          file_contents = [];
          fetch_file;
          trigger = Local;
          source_kind = Local;
        }
    in
    Lwt.return (Ok { job; filtered_diff })

let prepare_review ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () =
  match%lwt read_file diff_path with
  | Error msg -> Lwt.return (Error (Read_failed msg))
  | Ok diff_text -> prepare_review_from_text ~root ~repo_key ?change_key ~title ~description ~diff_text ~config ()
