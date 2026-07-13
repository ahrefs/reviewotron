type run_git = cwd:string -> string list -> (string, string) result

let close_fd_noerr fd = try Unix.close fd with Unix.Unix_error _ -> ()

let waitpid_noerr pid =
  let rec loop () =
    match Unix.waitpid [] pid with
    | _pid, status -> Some status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception Unix.Unix_error _ -> None
  in
  loop ()

let read_all ic =
  let buffer = Buffer.create 4096 in
  let bytes = Bytes.create 4096 in
  let rec loop () =
    match input ic bytes 0 (Bytes.length bytes) with
    | 0 -> Buffer.contents buffer
    | n ->
      Buffer.add_subbytes buffer bytes 0 n;
      loop ()
  in
  loop ()

let git_command ~cwd args = Printf.sprintf "git -C %s %s" cwd (String.concat " " args)

let run_git ~cwd args =
  let process_args = Array.of_list ("git" :: "-C" :: cwd :: args) in
  try
    let stdout_r, stdout_w = Unix.pipe () in
    let dev_null =
      match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
      | dev_null -> dev_null
      | exception exn ->
        close_fd_noerr stdout_r;
        close_fd_noerr stdout_w;
        raise exn
    in
    let pid =
      try Unix.create_process "git" process_args dev_null stdout_w dev_null
      with exn ->
        close_fd_noerr stdout_r;
        close_fd_noerr stdout_w;
        close_fd_noerr dev_null;
        raise exn
    in
    close_fd_noerr stdout_w;
    close_fd_noerr dev_null;
    let ic = Unix.in_channel_of_descr stdout_r in
    let status = ref None in
    let output =
      Fun.protect
        ~finally:(fun () ->
          close_in_noerr ic;
          status := waitpid_noerr pid)
        (fun () -> read_all ic)
    in
    match !status with
    | None -> Error (Printf.sprintf "git %s waitpid failed" (String.concat " " args))
    | Some status ->
    match status with
    | Unix.WEXITED 0 -> Ok (String.trim output)
    | Unix.WEXITED code -> Error (Printf.sprintf "git %s exited with %d" (String.concat " " args) code)
    | Unix.WSIGNALED signal -> Error (Printf.sprintf "git %s killed by signal %d" (String.concat " " args) signal)
    | Unix.WSTOPPED signal -> Error (Printf.sprintf "git %s stopped by signal %d" (String.concat " " args) signal)
  with exn -> Error (Printf.sprintf "%s failed: %s" (git_command ~cwd args) (Printexc.to_string exn))

let absolute_path path =
  match Filename.is_relative path with
  | true -> Filename.concat (Sys.getcwd ()) path
  | false -> path

let normalize_path path =
  let path = absolute_path path in
  try Unix.realpath path with Unix.Unix_error _ -> path

let discover_root ~cwd =
  match run_git ~cwd [ "rev-parse"; "--show-toplevel" ] with
  | Ok root -> Ok (normalize_path root)
  | Error _ as error -> error

let default_root ~cwd =
  match discover_root ~cwd with
  | Ok root -> root
  | Error _ -> normalize_path cwd

let default_repo_key ~root = "local:" ^ normalize_path root

let title_for_base base = Printf.sprintf "Review current changes against %s" base

let title_for_diff_file diff_path = Printf.sprintf "Review local diff %s" diff_path

let remote_of_tracking tracking =
  match String.split_on_char '/' tracking with
  | remote :: _branch :: _ -> Some remote
  | [] | [ _ ] -> None

let remote_head_with ~run_git ~root remote =
  let refname = Printf.sprintf "refs/remotes/%s/HEAD" remote in
  match run_git ~cwd:root [ "symbolic-ref"; "--quiet"; "--short"; refname ] with
  | Ok "" -> None
  | Ok head -> Some head
  | Error _ -> None

let remote_candidates_with ~run_git ~root remote =
  [ remote_head_with ~run_git ~root remote; Some (remote ^ "/main"); Some (remote ^ "/master") ]

let upstream_remote_with ~run_git ~root =
  match run_git ~cwd:root [ "rev-parse"; "--abbrev-ref"; "--symbolic-full-name"; "@{upstream}" ] with
  | Ok tracking -> remote_of_tracking tracking
  | Error _ -> None

let unique_strings strings =
  strings |> List.fold_left (fun seen s -> if List.exists (String.equal s) seen then seen else s :: seen) [] |> List.rev

let candidate_bases_with ~run_git ~root =
  let origin_candidates = remote_candidates_with ~run_git ~root "origin" in
  let extra_remote_candidates =
    match upstream_remote_with ~run_git ~root with
    | Some remote when not (String.equal remote "origin") -> remote_candidates_with ~run_git ~root remote
    | Some _ | None -> []
  in
  List.concat [ origin_candidates; extra_remote_candidates ] |> List.filter_map Fun.id |> unique_strings

let merge_base_with ~run_git ~root ~base = run_git ~cwd:root [ "merge-base"; "HEAD"; base ]

let base_exists_with ~run_git ~root base =
  let refname = base ^ "^{commit}" in
  match run_git ~cwd:root [ "rev-parse"; "--verify"; "--quiet"; refname ] with
  | Ok _ -> true
  | Error _ -> false

let infer_base_with ~run_git ~root ~explicit =
  let verify_explicit base =
    match base_exists_with ~run_git ~root base with
    | false -> Error (Printf.sprintf "could not find base ref %s" base)
    | true ->
    match merge_base_with ~run_git ~root ~base with
    | Ok _ -> Ok base
    | Error msg -> Error (Printf.sprintf "could not use base %s: %s" base msg)
  in
  match explicit with
  | Some base -> verify_explicit base
  | None ->
    let rec first_valid = function
      | [] -> Error "could not infer a base ref; pass --base or --diff"
      | base :: rest ->
      match base_exists_with ~run_git ~root base with
      | false -> first_valid rest
      | true ->
      match merge_base_with ~run_git ~root ~base with
      | Ok _ -> Ok base
      | Error _ -> first_valid rest
    in
    first_valid (candidate_bases_with ~run_git ~root)

let infer_base ~root ~explicit = infer_base_with ~run_git ~root ~explicit

let diff_against_base_with ~run_git ~root ~base =
  match merge_base_with ~run_git ~root ~base with
  | Error msg -> Error (Printf.sprintf "could not find merge-base with %s: %s" base msg)
  | Ok merge_base -> run_git ~cwd:root [ "diff"; merge_base ]

let diff_against_base ~root ~base = diff_against_base_with ~run_git ~root ~base

let untracked_files_with ~run_git ~root =
  match run_git ~cwd:root [ "ls-files"; "--others"; "--exclude-standard"; "-z" ] with
  | Error msg -> Error (Printf.sprintf "could not discover untracked files: %s" msg)
  | Ok output -> Ok (String.split_on_char '\000' output |> List.filter (fun path -> not (String.equal path "")))

let untracked_files ~root = untracked_files_with ~run_git ~root
