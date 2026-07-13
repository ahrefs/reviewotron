type requested_mode =
  | Auto
  | Diff
  | Path

type path_selection = {
  path : string;
  project_root : string;
}

type diff_selection = {
  root : string;
  base : string;
  tracked_diff : string;
  untracked_files : string list;
}

type selection =
  | Review_path of path_selection
  | Review_diff of diff_selection

type path_kind =
  | File
  | Directory

let path_kind path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> Ok File
  | { Unix.st_kind = Unix.S_DIR; _ } -> Ok Directory
  | { Unix.st_kind = Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Error (Printf.sprintf "%s is not a regular file or directory" path)
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "cannot read %s: %s" path (Unix.error_message error))

let working_directory path = function
  | File -> Filename.dirname path
  | Directory -> path

let project_root ~discover_root ~root ~path ~kind =
  match root with
  | Some root -> Ok (Local_git.normalize_path root)
  | None ->
    let cwd = working_directory path kind in
    (match discover_root ~cwd with
    | Ok root -> Ok root
    | Error _ -> Ok (Local_git.normalize_path cwd))

let git_root ~discover_root ~root ~path ~kind =
  let cwd =
    match root with
    | Some root -> Local_git.normalize_path root
    | None -> working_directory path kind
  in
  discover_root ~cwd

let diff_selection ~infer_base ~diff_against_base ~untracked_files ~root ~base =
  match infer_base ~root ~explicit:base with
  | Error _ when Option.is_none base -> Error "could not infer a base ref; pass --base or use --mode path"
  | Error msg -> Error msg
  | Ok base ->
  match diff_against_base ~root ~base with
  | Error msg -> Error msg
  | Ok tracked_diff ->
  match untracked_files ~root with
  | Error msg -> Error msg
  | Ok untracked_files ->
  match String.equal tracked_diff "", untracked_files with
  | true, [] -> Error "no changes to review"
  | false, [] | true, _ :: _ | false, _ :: _ -> Ok (Review_diff { root; base; tracked_diff; untracked_files })

let select_with ~discover_root ~infer_base ~diff_against_base ~untracked_files ~requested_mode ~path ~root ~base =
  match path_kind path with
  | Error _ as error -> error
  | Ok kind ->
    let project_root = project_root ~discover_root ~root ~path ~kind in
    (match requested_mode with
    | Path -> Result.map (fun project_root -> Review_path { path; project_root }) project_root
    | Auto ->
      (match kind with
      | File -> Result.map (fun project_root -> Review_path { path; project_root }) project_root
      | Directory ->
      match git_root ~discover_root ~root ~path ~kind with
      | Ok root -> diff_selection ~infer_base ~diff_against_base ~untracked_files ~root ~base
      | Error _ -> Result.map (fun project_root -> Review_path { path; project_root }) project_root)
    | Diff ->
    match git_root ~discover_root ~root ~path ~kind with
    | Error _ -> Error "diff mode requires a Git worktree; use --mode path"
    | Ok root -> diff_selection ~infer_base ~diff_against_base ~untracked_files ~root ~base)

let select ~requested_mode ~path ~root ~base =
  select_with ~discover_root:Local_git.discover_root ~infer_base:Local_git.infer_base
    ~diff_against_base:Local_git.diff_against_base ~untracked_files:Local_git.untracked_files ~requested_mode ~path
    ~root ~base
