type diff_line =
  | Context of string
  | Addition of string
  | Deletion of string

type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  lines : diff_line list;
}

type file_status =
  | Added
  | Deleted
  | Modified
  | Renamed

type file_diff = {
  path : string;
  old_path : string option;
  status : file_status;
  hunks : hunk list;
}

type t = file_diff list

type side =
  | Left
  | Right

(** {2 Regex patterns} *)

let hunk_header_re = Re2.create_exn {|^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@|}
let diff_git_re = Re2.create_exn {|^diff --git a/(.*) b/(.*)$|}
let minus_file_re = Re2.create_exn {|^--- a/(.*)$|}
let plus_file_re = Re2.create_exn {|^\+\+\+ b/(.*)$|}
let rename_from_re = Re2.create_exn {|^rename from (.*)$|}
let new_file_re = Re2.create_exn {|^new file mode|}
let deleted_file_re = Re2.create_exn {|^deleted file mode|}
let diff_git_split_re = Re2.create_exn {|\ndiff --git |}

(** {2 Parsing helpers} *)

let try_submatches re s =
  try Some (Re2.find_submatches_exn re s)
  with exn ->
    ignore (exn : exn);
    None

let extract_submatch re s idx =
  match try_submatches re s with
  | Some matches when idx < Array.length matches -> matches.(idx)
  | _ -> None

let parse_hunk_header line =
  match try_submatches hunk_header_re line with
  | Some [| _; Some os; oc_opt; Some ns; nc_opt |] ->
    let old_start = int_of_string os in
    let old_count = CCOption.map_or ~default:1 int_of_string oc_opt in
    let new_start = int_of_string ns in
    let new_count = CCOption.map_or ~default:1 int_of_string nc_opt in
    Some { old_start; old_count; new_start; new_count; lines = [] }
  | _ -> None

let classify_line line =
  match String.length line with
  | 0 -> Context ""
  | _ ->
    let first = line.[0] in
    let rest = String.sub line 1 (String.length line - 1) in
    (match first with
    | '+' -> Addition rest
    | '-' -> Deletion rest
    | ' ' -> Context rest
    | _ -> Context line)

(** Parse hunks from lines within a single file section.
    Accumulates lines in reverse for each hunk, then reverses at the end. *)
let parse_hunks lines =
  let finalize_hunk h = { h with lines = List.rev h.lines } in
  let rec aux acc current_hunk = function
    | [] ->
      let all =
        match current_hunk with
        | Some h -> finalize_hunk h :: acc
        | None -> acc
      in
      List.rev all
    | line :: rest ->
    match parse_hunk_header line with
    | Some new_hunk ->
      let acc' =
        match current_hunk with
        | Some h -> finalize_hunk h :: acc
        | None -> acc
      in
      aux acc' (Some new_hunk) rest
    | None ->
    match current_hunk with
    | Some h ->
      let dl = classify_line line in
      aux acc (Some { h with lines = dl :: h.lines }) rest
    | None ->
      (* Skip lines before first hunk header *)
      aux acc None rest
  in
  aux [] None lines

(** Detect file status from the header lines between "diff --git" and first hunk *)
let detect_status header_lines =
  let is_new = List.exists (fun l -> Re2.matches new_file_re l) header_lines in
  let is_deleted = List.exists (fun l -> Re2.matches deleted_file_re l) header_lines in
  let is_rename = List.exists (fun l -> Re2.matches rename_from_re l) header_lines in
  match () with
  | () when is_new -> Added
  | () when is_deleted -> Deleted
  | () when is_rename -> Renamed
  | () -> Modified

let extract_rename_from header_lines = List.find_map (fun l -> extract_submatch rename_from_re l 1) header_lines

(** Parse a single file section (everything after "diff --git" up to the next one) *)
let parse_file_section section =
  let lines = String.split_on_char '\n' section in
  match lines with
  | [] -> None
  | first_line :: rest ->
    (* Extract paths from "diff --git a/... b/..." *)
    let git_a, git_b =
      match try_submatches diff_git_re first_line with
      | Some [| _; Some a; Some b |] -> Some a, Some b
      | _ -> None, None
    in
    (* Split into header lines and hunk lines *)
    let header_lines, hunk_lines =
      let rec split_at_hunk acc = function
        | [] -> List.rev acc, []
        | line :: _ as remaining when Re2.matches hunk_header_re line -> List.rev acc, remaining
        | line :: rest -> split_at_hunk (line :: acc) rest
      in
      split_at_hunk [] rest
    in
    (* Extract paths from --- and +++ lines *)
    let minus_path = List.find_map (fun l -> extract_submatch minus_file_re l 1) header_lines in
    let plus_path = List.find_map (fun l -> extract_submatch plus_file_re l 1) header_lines in
    let status = detect_status header_lines in
    let path =
      match plus_path, minus_path, git_b with
      | Some p, _, _ -> p
      | None, _, Some b -> b
      | None, Some m, None -> m
      | None, None, None -> "unknown"
    in
    let old_path =
      match status with
      | Renamed -> extract_rename_from header_lines
      | Added | Deleted | Modified ->
      match minus_path, git_a with
      | Some m, _ when not (String.equal m path) -> Some m
      | _, Some a when not (String.equal a path) -> Some a
      | _ -> None
    in
    let hunks = parse_hunks hunk_lines in
    Some { path; old_path; status; hunks }

(** {2 Public API} *)

let parse diff_text =
  match String.length diff_text with
  | 0 -> []
  | _ ->
    (* Split on "diff --git" boundaries, keeping the delimiter *)
    let sections =
      let parts = Re2.split diff_git_split_re diff_text in
      match parts with
      | [] -> []
      | first :: rest ->
        let first' =
          (* First section starts with "diff --git " already, or needs prefix *)
          if String.length first >= 11 && String.sub first 0 11 = "diff --git " then first else "diff --git " ^ first
        in
        first' :: List.map (fun s -> "diff --git " ^ s) rest
    in
    List.filter_map parse_file_section sections

(** Advance old/new line counters based on a diff line *)
let advance_lines old_line new_line = function
  | Context _ -> old_line + 1, new_line + 1
  | Deletion _ -> old_line + 1, new_line
  | Addition _ -> old_line, new_line + 1

let line_to_position file_diff ~line ~side =
  let rec search_hunks position hunks =
    match hunks with
    | [] -> None
    | hunk :: rest_hunks ->
      let header_pos = position in
      let rec search_lines pos old_line new_line = function
        | [] -> None
        | dl :: rest ->
          let found =
            match dl, side with
            | Context _, Right -> new_line = line
            | Context _, Left -> old_line = line
            | Addition _, Right -> new_line = line
            | Deletion _, Left -> old_line = line
            | Addition _, Left -> false
            | Deletion _, Right -> false
          in
          if found then Some pos
          else (
            let old_line', new_line' = advance_lines old_line new_line dl in
            search_lines (pos + 1) old_line' new_line' rest)
      in
      let result = search_lines (header_pos + 1) hunk.old_start hunk.new_start hunk.lines in
      (match result with
      | Some _ -> result
      | None ->
        let next_position = header_pos + 1 + List.length hunk.lines in
        search_hunks next_position rest_hunks)
  in
  search_hunks 1 file_diff.hunks

let position_to_line file_diff ~position =
  let rec search_hunks pos hunks =
    match hunks with
    | [] -> None
    | hunk :: rest_hunks ->
      let header_pos = pos in
      if position = header_pos then
        (* Pointing at the hunk header itself *)
        Some (hunk.new_start, Right)
      else (
        let rec search_lines p old_line new_line = function
          | [] -> None
          | dl :: rest ->
            if p = position then (
              match dl with
              | Context _ -> Some (new_line, Right)
              | Addition _ -> Some (new_line, Right)
              | Deletion _ -> Some (old_line, Left))
            else (
              let old_line', new_line' = advance_lines old_line new_line dl in
              search_lines (p + 1) old_line' new_line' rest)
        in
        let result = search_lines (header_pos + 1) hunk.old_start hunk.new_start hunk.lines in
        match result with
        | Some _ -> result
        | None ->
          let next_pos = header_pos + 1 + List.length hunk.lines in
          search_hunks next_pos rest_hunks)
  in
  search_hunks 1 file_diff.hunks

let total_lines diffs =
  List.fold_left (fun acc fd -> List.fold_left (fun acc2 hunk -> acc2 + List.length hunk.lines) acc fd.hunks) 0 diffs

(** Simple glob matching: supports [*] as wildcard *)
let glob_star_re = Re2.create_exn {|\\\*|}

let glob_to_re pattern =
  let escaped = Re2.escape pattern in
  let re_str = Re2.rewrite_exn glob_star_re escaped ~template:"[^/]*" in
  Re2.create_exn (Printf.sprintf "^%s$" re_str)

let filter_paths diffs ~ignored =
  let compiled = List.map glob_to_re ignored in
  List.filter (fun fd -> not (List.exists (fun re -> Re2.matches re fd.path) compiled)) diffs

let hunk_header_str hunk =
  Printf.sprintf "@@ -%d,%d +%d,%d @@" hunk.old_start hunk.old_count hunk.new_start hunk.new_count

let diff_line_str = function
  | Context s -> " " ^ s
  | Addition s -> "+" ^ s
  | Deletion s -> "-" ^ s

let file_diff_to_lines fd =
  let lines = ref [] in
  let add s = lines := s :: !lines in
  let old_path =
    match fd.old_path with
    | Some p -> p
    | None -> fd.path
  in
  add (Printf.sprintf "diff --git a/%s b/%s" old_path fd.path);
  (match fd.status with
  | Added -> add "new file mode 100644"
  | Deleted -> add "deleted file mode 100644"
  | Renamed ->
    add (Printf.sprintf "rename from %s" old_path);
    add (Printf.sprintf "rename to %s" fd.path)
  | Modified -> ());
  (match fd.status with
  | Deleted ->
    add (Printf.sprintf "--- a/%s" old_path);
    add "+++ /dev/null"
  | Added ->
    add "--- /dev/null";
    add (Printf.sprintf "+++ b/%s" fd.path)
  | Modified | Renamed ->
    add (Printf.sprintf "--- a/%s" old_path);
    add (Printf.sprintf "+++ b/%s" fd.path));
  List.iter
    (fun hunk ->
      add (hunk_header_str hunk);
      List.iter (fun dl -> add (diff_line_str dl)) hunk.lines)
    fd.hunks;
  List.rev !lines

let to_string diffs =
  let all_lines = List.concat_map file_diff_to_lines diffs in
  String.concat "\n" all_lines

let estimate_tokens diffs =
  let char_count =
    List.fold_left
      (fun acc fd ->
        List.fold_left
          (fun acc2 hunk ->
            List.fold_left
              (fun acc3 dl ->
                let s =
                  match dl with
                  | Context s -> s
                  | Addition s -> s
                  | Deletion s -> s
                in
                acc3 + String.length s + 1)
              acc2 hunk.lines)
          acc fd.hunks)
      0 diffs
  in
  (* ~4 chars per token *)
  (char_count + 3) / 4
