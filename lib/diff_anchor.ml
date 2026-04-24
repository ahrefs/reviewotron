(** Pure helpers for anchoring findings onto positions in a parsed diff. *)

let right_line_ranges (fd : Diff_parser.file_diff) =
  List.filter_map
    (fun (h : Diff_parser.hunk) ->
      match () with
      | () when h.new_count <= 0 -> None
      | () -> Some (h.new_start, h.new_start + h.new_count - 1))
    fd.hunks

let nearest_right_line_in_diff (fd : Diff_parser.file_diff) ~target_line =
  let pick_better best (start_line, end_line) =
    let candidate_line, distance =
      match () with
      | () when target_line < start_line -> start_line, start_line - target_line
      | () when target_line > end_line -> end_line, target_line - end_line
      | () -> target_line, 0
    in
    match best with
    | None -> Some (candidate_line, distance)
    | Some (_best_line, best_distance) when distance < best_distance -> Some (candidate_line, distance)
    | Some _ -> best
  in
  right_line_ranges fd |> List.fold_left pick_better None |> Option.map (fun (line, _distance) -> line)

let line_in_right_range (fd : Diff_parser.file_diff) ~line =
  List.exists (fun (start_line, end_line) -> line >= start_line && line <= end_line) (right_line_ranges fd)

let resolve_right_line (fd : Diff_parser.file_diff) ~target_line =
  match line_in_right_range fd ~line:target_line with
  | true -> Some target_line
  | false -> nearest_right_line_in_diff fd ~target_line

let single_hunk_contains (fd : Diff_parser.file_diff) ~start_line ~end_line =
  List.exists
    (fun (hs, he) -> start_line >= hs && end_line <= he)
    (right_line_ranges fd)

let rec drop_known_path_prefixes path =
  let len = String.length path in
  match () with
  | () when len >= 2 && String.sub path 0 2 = "./" -> drop_known_path_prefixes (String.sub path 2 (len - 2))
  | () when len >= 2 && String.sub path 0 2 = "a/" -> drop_known_path_prefixes (String.sub path 2 (len - 2))
  | () when len >= 2 && String.sub path 0 2 = "b/" -> drop_known_path_prefixes (String.sub path 2 (len - 2))
  | () when len >= 1 && String.sub path 0 1 = "/" -> drop_known_path_prefixes (String.sub path 1 (len - 1))
  | () -> path

let strip_backticks path =
  let len = String.length path in
  match () with
  | () when len >= 2 && path.[0] = '`' && path.[len - 1] = '`' -> String.sub path 1 (len - 2)
  | () -> path

let normalize_finding_path path = path |> String.trim |> strip_backticks |> drop_known_path_prefixes

let path_equivalent a b = String.equal a b || CCString.suffix ~suf:("/" ^ b) a || CCString.suffix ~suf:("/" ^ a) b

let path_matches_target path target =
  match path with
  | None -> false
  | Some p -> path_equivalent p target

let path_basename_matches_target path target =
  match path with
  | None -> false
  | Some p -> String.equal (Filename.basename p) (Filename.basename target)

let find_file_diff_by_path ~diff path =
  let target = normalize_finding_path path in
  let normalized_paths =
    List.map
      (fun (fd : Diff_parser.file_diff) ->
        let path = Some (normalize_finding_path fd.path) in
        let old_path = Option.map normalize_finding_path fd.old_path in
        fd, path, old_path)
      diff
  in
  let direct_matches =
    List.filter
      (fun (_fd, path, old_path) -> path_matches_target path target || path_matches_target old_path target)
      normalized_paths
  in
  match direct_matches with
  | (fd, _, _) :: _ -> Some fd
  | [] ->
    let basename_matches =
      List.filter
        (fun (_fd, path, old_path) ->
          path_basename_matches_target path target || path_basename_matches_target old_path target)
        normalized_paths
    in
    (match basename_matches with
    | [ (fd, _, _) ] -> Some fd
    | _ -> None)
