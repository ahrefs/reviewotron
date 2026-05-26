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

let safe_relative_path path =
  Filename.is_relative path
  &&
  match String.split_on_char '/' path with
  | [] -> false
  | parts ->
    List.for_all
      (function
        | "" | "." | ".." -> false
        | _ -> true)
      parts

let fetch_file_from_root ~root ~path =
  match safe_relative_path path with
  | false -> Lwt.return (Error (Printf.sprintf "refusing to read unsafe local path: %s" path))
  | true ->
    let full_path = Filename.concat root path in
    (match%lwt read_file full_path with
    | Ok contents -> Lwt.return (Ok (Some contents))
    | Error _ -> Lwt.return (Ok None))

let digest_change_key diff_text = Digest.(to_hex (string diff_text))

let prepare_diff ~config diff_text =
  match Review_engine.prepare_diff ~config diff_text with
  | Ok prepared -> Ok prepared
  | Error `Empty -> Error Empty
  | Error (`Too_large total_lines) -> Error (Too_large total_lines)

let prepare_review ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () =
  match%lwt read_file diff_path with
  | Error msg -> Lwt.return (Error (Read_failed msg))
  | Ok diff_text ->
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
