open Devkit

let log = Log.from "local_path"

type t = {
  root : string;
  diff_text : string;
  title : string;
  file_count : int;
}

let default_skip_dirs =
  [ "node_modules"; "_build"; "_opam"; "dist"; "build"; "target"; "vendor"; "venv"; "__pycache__"; "coverage" ]

let is_hidden name = String.length name > 0 && Char.equal name.[0] '.'

let should_skip_dir name = List.exists (String.equal name) default_skip_dirs

(* Diff paths are canonically slash-separated regardless of platform. *)
let join_rel rel name =
  match rel with
  | "" -> name
  | _ -> rel ^ "/" ^ name

(* Collect embeddable regular files under [root], as paths relative to [root],
   in stable sorted order. Per-entry failures are logged and skipped so one bad
   file or directory does not abort the whole walk. *)
let rec collect_dir ~root ~rel =
  let abs =
    match rel with
    | "" -> root
    | _ -> Filename.concat root rel
  in
  match Sys.readdir abs with
  | exception Sys_error msg ->
    log#warn "skipping unreadable directory %s: %s" abs msg;
    []
  | entries -> entries |> Array.to_list |> List.sort String.compare |> List.concat_map (collect_entry ~root ~rel)

and collect_entry ~root ~rel name =
  match is_hidden name with
  | true -> []
  | false ->
    let child_rel = join_rel rel name in
    (match Unix.lstat (Filename.concat root child_rel) with
    | exception Unix.Unix_error (error, _, _) ->
      log#warn "skipping %s: %s" child_rel (Unix.error_message error);
      []
    | st ->
    match st.Unix.st_kind with
    | Unix.S_REG -> [ child_rel ]
    | Unix.S_DIR ->
      (match should_skip_dir name with
      | true -> []
      | false -> collect_dir ~root ~rel:child_rel)
    | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> [])

let read_embeddable ~root rel =
  match Std.input_file ~bin:true (Filename.concat root rel) with
  | exception exn ->
    log#warn "skipping %s: %s" rel (Exn.str exn);
    None
  | content ->
  match Review_job.is_embeddable content with
  | true -> Some content
  | false ->
    log#info "skipping %s: not embeddable (binary or too large)" rel;
    None

(* Render one file's content as a newly-added file diff. A single trailing
   newline is dropped so the synthesized file does not gain a phantom blank
   final line; the parser round-trips this form back to the same structure. *)
let added_file_diff ~path content =
  let content =
    let n = String.length content in
    match n > 0 && Char.equal content.[n - 1] '\n' with
    | true -> String.sub content 0 (n - 1)
    | false -> content
  in
  let lines = content |> String.split_on_char '\n' |> List.map (fun line -> Diff_parser.Addition line) in
  let count = List.length lines in
  Diff_parser.
    {
      path;
      old_path = None;
      status = Added;
      hunks = [ { old_start = 0; old_count = 0; new_start = 1; new_count = count; lines } ];
    }

let classify path =
  match Unix.stat path with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "cannot read %s: %s" path (Unix.error_message error))
  | st ->
  match st.Unix.st_kind with
  | Unix.S_DIR ->
    let root = Local_git.normalize_path path in
    Ok (root, collect_dir ~root ~rel:"", Printf.sprintf "Review directory %s" path)
  | Unix.S_REG ->
    let root = Local_git.normalize_path (Filename.dirname path) in
    let base = Filename.basename path in
    Ok (root, [ base ], Printf.sprintf "Review file %s" base)
  | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
    Error (Printf.sprintf "%s is not a regular file or directory" path)

let ingest path =
  match classify path with
  | Error _ as error -> error
  | Ok (root, rels, title) ->
    let file_diffs =
      List.filter_map (fun rel -> Option.map (added_file_diff ~path:rel) (read_embeddable ~root rel)) rels
    in
    (match file_diffs with
    | [] -> Error (Printf.sprintf "no reviewable files found in %s" path)
    | _ :: _ -> Ok { root; diff_text = Diff_parser.to_string file_diffs; title; file_count = List.length file_diffs })

let has_hidden_or_skipped_component path =
  String.split_on_char '/' path |> List.exists (fun component -> is_hidden component || should_skip_dir component)

let safe_relative_path path =
  match Filename.is_relative path with
  | false -> false
  | true ->
    String.split_on_char '/' path
    |> List.for_all (fun component ->
      not (String.equal component "" || String.equal component "." || String.equal component ".."))

let regular_file ~root path =
  match Unix.lstat (Filename.concat root path) with
  | { Unix.st_kind = Unix.S_REG; _ } -> true
  | _ -> false
  | exception Unix.Unix_error _ -> false

let added_files_diff ~root ~paths =
  let root = Local_git.normalize_path root in
  let file_diffs =
    paths
    |> List.sort_uniq String.compare
    |> List.filter (fun path -> safe_relative_path path && not (has_hidden_or_skipped_component path))
    |> List.filter (regular_file ~root)
    |> List.filter_map (fun path -> Option.map (added_file_diff ~path) (read_embeddable ~root path))
  in
  Diff_parser.to_string file_diffs
