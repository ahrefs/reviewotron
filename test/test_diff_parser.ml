open Reviewotron_lib
open Alcotest

let read_file path = Std.input_file ~bin:true path

let file_status_to_string : Diff_parser.file_status -> string = function
  | Added -> "Added"
  | Deleted -> "Deleted"
  | Modified -> "Modified"
  | Renamed -> "Renamed"

let pp_file_status fmt s = Format.pp_print_string fmt (file_status_to_string s)

let equal_file_status (a : Diff_parser.file_status) (b : Diff_parser.file_status) =
  match a, b with
  | Added, Added -> true
  | Deleted, Deleted -> true
  | Modified, Modified -> true
  | Renamed, Renamed -> true
  | (Added | Deleted | Modified | Renamed), _ -> false

let file_status_testable = testable pp_file_status equal_file_status

let hd_exn msg = function
  | x :: _ -> x
  | [] -> fail (Printf.sprintf "expected non-empty list: %s" msg)

(** {2 Basic parsing tests} *)

let single_hunk_diff =
  String.concat "\n"
    [
      "diff --git a/foo.ml b/foo.ml";
      "index 1234567..abcdefg 100644";
      "--- a/foo.ml";
      "+++ b/foo.ml";
      "@@ -1,4 +1,5 @@";
      " let x = 1";
      "-let y = 2";
      "+let y = 3";
      "+let z = 4";
      " let w = 5";
    ]

let test_basic_single_hunk () =
  let diffs = Diff_parser.parse single_hunk_diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check string) "path" "foo.ml" fd.path;
  (check file_status_testable) "status" Modified fd.status;
  (check int) "one hunk" 1 (List.length fd.hunks);
  let hunk = hd_exn "hunks" fd.hunks in
  (check int) "old_start" 1 hunk.old_start;
  (check int) "old_count" 4 hunk.old_count;
  (check int) "new_start" 1 hunk.new_start;
  (check int) "new_count" 5 hunk.new_count;
  (check int) "line count" 5 (List.length hunk.lines)

(** {2 Multi-hunk tests} *)

let multi_hunk_diff =
  String.concat "\n"
    [
      "diff --git a/bar.ml b/bar.ml";
      "index 1234567..abcdefg 100644";
      "--- a/bar.ml";
      "+++ b/bar.ml";
      "@@ -1,3 +1,4 @@";
      " let a = 1";
      "+let b = 2";
      " let c = 3";
      " let d = 4";
      "@@ -10,3 +11,4 @@";
      " let x = 10";
      "-let y = 11";
      "+let y = 111";
      "+let z = 12";
      " let w = 13";
    ]

let test_multi_hunk () =
  let diffs = Diff_parser.parse multi_hunk_diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check int) "two hunks" 2 (List.length fd.hunks);
  match fd.hunks with
  | h1 :: h2 :: _ ->
    (check int) "h1 old_start" 1 h1.old_start;
    (check int) "h1 new_count" 4 h1.new_count;
    (check int) "h2 old_start" 10 h2.old_start;
    (check int) "h2 new_count" 4 h2.new_count
  | _ -> fail "expected at least two hunks"

(** {2 Multi-file tests} *)

let test_multi_file () =
  let diff = read_file "mock_api_responses/github/pr_1.diff" in
  let diffs = Diff_parser.parse diff in
  (check int) "two files" 2 (List.length diffs);
  match diffs with
  | f1 :: f2 :: _ ->
    (check string) "first file path" "src/main.ml" f1.path;
    (check file_status_testable) "first file status" Modified f1.status;
    (check string) "second file path" "src/utils.ml" f2.path;
    (check file_status_testable) "second file status" Added f2.status
  | _ -> fail "expected at least two files"

(** {2 Position mapping tests} *)

let test_position_mapping_single_hunk () =
  let diffs = Diff_parser.parse single_hunk_diff in
  let fd = hd_exn "diffs" diffs in
  (check (option int)) "context line 1 right" (Some 2) (Diff_parser.line_to_position fd ~line:1 ~side:Right);
  (check (option int)) "context line 1 left" (Some 2) (Diff_parser.line_to_position fd ~line:1 ~side:Left);
  (check (option int)) "deleted line 2 left" (Some 3) (Diff_parser.line_to_position fd ~line:2 ~side:Left);
  (check (option int)) "added line 2 right" (Some 4) (Diff_parser.line_to_position fd ~line:2 ~side:Right);
  (check (option int)) "added line 3 right" (Some 5) (Diff_parser.line_to_position fd ~line:3 ~side:Right);
  (check (option int)) "context line 4 right" (Some 6) (Diff_parser.line_to_position fd ~line:4 ~side:Right);
  (check (option int)) "line 100 not found" None (Diff_parser.line_to_position fd ~line:100 ~side:Right)

let test_position_mapping_multi_hunk () =
  let diffs = Diff_parser.parse multi_hunk_diff in
  let fd = hd_exn "diffs" diffs in
  (check (option int)) "hunk1 context new=1" (Some 2) (Diff_parser.line_to_position fd ~line:1 ~side:Right);
  (check (option int)) "hunk1 add new=2" (Some 3) (Diff_parser.line_to_position fd ~line:2 ~side:Right);
  (check (option int)) "hunk2 context new=11" (Some 7) (Diff_parser.line_to_position fd ~line:11 ~side:Right);
  (check (option int)) "hunk2 del old=11" (Some 8) (Diff_parser.line_to_position fd ~line:11 ~side:Left);
  (check (option int)) "hunk2 add new=12" (Some 9) (Diff_parser.line_to_position fd ~line:12 ~side:Right);
  (check (option int)) "hunk2 context new=14" (Some 11) (Diff_parser.line_to_position fd ~line:14 ~side:Right)

let test_position_to_line () =
  let diffs = Diff_parser.parse single_hunk_diff in
  let fd = hd_exn "diffs" diffs in
  let check_pos pos expected_line expected_side =
    let side_str (s : Diff_parser.side) =
      match s with
      | Left -> "Left"
      | Right -> "Right"
    in
    match Diff_parser.position_to_line fd ~position:pos with
    | Some (line, side) ->
      (check int) (Printf.sprintf "pos %d line" pos) expected_line line;
      (check string) (Printf.sprintf "pos %d side" pos) (side_str expected_side) (side_str side)
    | None -> fail (Printf.sprintf "position %d returned None" pos)
  in
  check_pos 2 1 Right;
  check_pos 3 2 Left;
  check_pos 4 2 Right;
  check_pos 5 3 Right;
  check_pos 6 4 Right

(** {2 Edge case tests} *)

let test_empty_diff () =
  let diffs = Diff_parser.parse "" in
  (check int) "empty" 0 (List.length diffs)

let test_new_file () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/new.ml b/new.ml";
        "new file mode 100644";
        "index 0000000..abcdefg";
        "--- /dev/null";
        "+++ b/new.ml";
        "@@ -0,0 +1,3 @@";
        "+let x = 1";
        "+let y = 2";
        "+let z = 3";
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check string) "path" "new.ml" fd.path;
  (check file_status_testable) "status" Added fd.status;
  (check int) "one hunk" 1 (List.length fd.hunks);
  let hunk = hd_exn "hunks" fd.hunks in
  (check int) "3 lines" 3 (List.length hunk.lines)

let test_deleted_file () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/old.ml b/old.ml";
        "deleted file mode 100644";
        "index abcdefg..0000000";
        "--- a/old.ml";
        "+++ /dev/null";
        "@@ -1,2 +0,0 @@";
        "-let x = 1";
        "-let y = 2";
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check file_status_testable) "status" Deleted fd.status

let test_renamed_file () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/old_name.ml b/new_name.ml";
        "similarity index 90%";
        "rename from old_name.ml";
        "rename to new_name.ml";
        "index 1234567..abcdefg 100644";
        "--- a/old_name.ml";
        "+++ b/new_name.ml";
        "@@ -1,3 +1,3 @@";
        " let a = 1";
        "-let b = 2";
        "+let b = 3";
        " let c = 4";
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check string) "path" "new_name.ml" fd.path;
  (check file_status_testable) "status" Renamed fd.status;
  (check (option string)) "old_path" (Some "old_name.ml") fd.old_path

(** {2 Additional diff edge cases} *)

let test_binary_file_in_diff () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/image.png b/image.png";
        "new file mode 100644";
        "index 0000000..abcdefg";
        "Binary files /dev/null and b/image.png differ";
        "";
        "diff --git a/code.ml b/code.ml";
        "index 1234567..abcdefg 100644";
        "--- a/code.ml";
        "+++ b/code.ml";
        "@@ -1,2 +1,2 @@";
        "-let x = 1";
        "+let x = 2";
      ]
  in
  let diffs = Diff_parser.parse diff in
  (* Binary file has no hunks, code file does *)
  let with_hunks = List.filter (fun (fd : Diff_parser.file_diff) -> fd.hunks <> []) diffs in
  (check int) "one file with hunks" 1 (List.length with_hunks);
  let fd = hd_exn "with hunks" with_hunks in
  (check string) "code file" "code.ml" fd.path

let test_no_newline_at_end_marker () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/foo.ml b/foo.ml";
        "index 1234567..abcdefg 100644";
        "--- a/foo.ml";
        "+++ b/foo.ml";
        "@@ -1,3 +1,3 @@";
        " let x = 1";
        "-let y = 2";
        "+let y = 3";
        {|\ No newline at end of file|};
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check int) "one hunk" 1 (List.length fd.hunks);
  let hunk = hd_exn "hunks" fd.hunks in
  (* The "no newline" marker is treated as a context line by the parser *)
  (check bool) "lines parsed" true (List.length hunk.lines >= 3)

let test_permission_only_change () =
  let diff = String.concat "\n" [ "diff --git a/script.sh b/script.sh"; "old mode 100644"; "new mode 100755" ] in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check string) "path" "script.sh" fd.path;
  (check int) "no hunks" 0 (List.length fd.hunks)

let test_unicode_content () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/i18n.ml b/i18n.ml";
        "index 1234567..abcdefg 100644";
        "--- a/i18n.ml";
        "+++ b/i18n.ml";
        "@@ -1,3 +1,3 @@";
        {| let greeting = "Hello"|};
        {|-let farewell = "Goodbye"|};
        {|+let farewell = "\xC3\xA9\xC3\xA0\xC3\xBC \xE4\xB8\xAD\xE6\x96\x87"|};
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "one file" 1 (List.length diffs);
  let fd = hd_exn "diffs" diffs in
  (check string) "path" "i18n.ml" fd.path;
  let hunk = hd_exn "hunks" fd.hunks in
  (check int) "3 lines" 3 (List.length hunk.lines);
  (* Verify the unicode content survived parsing *)
  let last_line = List.nth hunk.lines 2 in
  match last_line with
  | Diff_parser.Addition s -> (check bool) "unicode preserved" true (String.length s > 0)
  | _ -> fail "expected Addition line"

let test_very_long_hunk_positions () =
  (* Build a hunk with > 100 lines to verify position mapping works at high offsets *)
  let lines = ref [] in
  for i = 150 downto 1 do
    lines := Printf.sprintf "+let line_%d = %d" i i :: !lines
  done;
  let diff_lines =
    [
      "diff --git a/big.ml b/big.ml";
      "new file mode 100644";
      "index 0000000..abcdefg";
      "--- /dev/null";
      "+++ b/big.ml";
      Printf.sprintf "@@ -0,0 +1,%d @@" 150;
    ]
    @ !lines
  in
  let diff = String.concat "\n" diff_lines in
  let diffs = Diff_parser.parse diff in
  let fd = hd_exn "diffs" diffs in
  (* Position for line 150 should be 151 (1 for header + 150 lines) *)
  (check (option int)) "line 150 position" (Some 151) (Diff_parser.line_to_position fd ~line:150 ~side:Right);
  (* Verify reverse mapping *)
  match Diff_parser.position_to_line fd ~position:151 with
  | Some (line, _side) -> (check int) "position 151 -> line 150" 150 line
  | None -> fail "position 151 returned None"

let test_multiple_hunks_continuous_positions () =
  (* Verify positions are continuous across hunks (no gaps) *)
  let diffs = Diff_parser.parse multi_hunk_diff in
  let fd = hd_exn "diffs" diffs in
  (* Hunk 1: 4 lines + 1 header = 5 positions (1-5)
     Hunk 2: 5 lines + 1 header, starting at position 6 *)
  let all_positions =
    List.init 11 (fun i ->
      let pos = i + 1 in
      pos, Diff_parser.position_to_line fd ~position:pos)
  in
  let valid_count = List.length (List.filter (fun (_pos, result) -> Option.is_some result) all_positions) in
  (* All 11 positions (2 headers + 9 lines) should resolve *)
  (check int) "all positions resolve" 11 valid_count

(** {2 Filtering tests} *)

let test_filter_paths () =
  let diff =
    String.concat "\n"
      [
        "diff --git a/src/main.ml b/src/main.ml";
        "--- a/src/main.ml";
        "+++ b/src/main.ml";
        "@@ -1,2 +1,2 @@";
        "-let x = 1";
        "+let x = 2";
        "";
        "diff --git a/test/test.ml b/test/test.ml";
        "--- a/test/test.ml";
        "+++ b/test/test.ml";
        "@@ -1,2 +1,2 @@";
        "-let t = 1";
        "+let t = 2";
        "";
        "diff --git a/vendor/lib.ml b/vendor/lib.ml";
        "--- a/vendor/lib.ml";
        "+++ b/vendor/lib.ml";
        "@@ -1,2 +1,2 @@";
        "-let v = 1";
        "+let v = 2";
      ]
  in
  let diffs = Diff_parser.parse diff in
  (check int) "three files before filter" 3 (List.length diffs);
  let filtered = Diff_parser.filter_paths diffs ~ignored:[ "test/*"; "vendor/*" ] in
  (check int) "one file after filter" 1 (List.length filtered);
  let fd = hd_exn "filtered" filtered in
  (check string) "kept src/main.ml" "src/main.ml" fd.path

(** {2 Token estimation tests} *)

let test_estimate_tokens () =
  let diffs = Diff_parser.parse single_hunk_diff in
  let tokens = Diff_parser.estimate_tokens diffs in
  (check bool) "tokens > 0" true (tokens > 0);
  (check bool) "tokens reasonable" true (tokens < 1000)

(** {2 Total lines tests} *)

let test_total_lines () =
  let diffs = Diff_parser.parse single_hunk_diff in
  (check int) "total lines" 5 (Diff_parser.total_lines diffs)

let test_total_lines_multi_hunk () =
  let diffs = Diff_parser.parse multi_hunk_diff in
  (check int) "total lines" 9 (Diff_parser.total_lines diffs)

(** {2 to_string roundtrip tests} *)

let test_to_string_roundtrip () =
  let diffs = Diff_parser.parse single_hunk_diff in
  let reconstructed = Diff_parser.to_string diffs in
  let re_parsed = Diff_parser.parse reconstructed in
  (check int) "same file count" (List.length diffs) (List.length re_parsed);
  let orig = hd_exn "orig" diffs in
  let round = hd_exn "round" re_parsed in
  (check string) "same path" orig.path round.path;
  (check int) "same hunk count" (List.length orig.hunks) (List.length round.hunks);
  (check int) "same total lines" (Diff_parser.total_lines diffs) (Diff_parser.total_lines re_parsed)

let test_to_string_multi_file_roundtrip () =
  let diff_text = read_file "mock_api_responses/github/pr_1.diff" in
  let diffs = Diff_parser.parse diff_text in
  let reconstructed = Diff_parser.to_string diffs in
  let re_parsed = Diff_parser.parse reconstructed in
  (check int) "same file count" (List.length diffs) (List.length re_parsed);
  List.iter2
    (fun (orig : Diff_parser.file_diff) (round : Diff_parser.file_diff) ->
      (check string) "same path" orig.path round.path;
      check file_status_testable "same status" orig.status round.status;
      (check int) "same hunk count" (List.length orig.hunks) (List.length round.hunks))
    diffs re_parsed;
  (check int) "same total lines" (Diff_parser.total_lines diffs) (Diff_parser.total_lines re_parsed)

let test_to_string_preserves_filter () =
  let diff_text = read_file "mock_api_responses/github/pr_1.diff" in
  let diffs = Diff_parser.parse diff_text in
  let file_count = List.length diffs in
  if file_count > 1 then begin
    let first_path = (hd_exn "first" diffs).path in
    let filtered = Diff_parser.filter_paths diffs ~ignored:[ first_path ] in
    let filtered_text = Diff_parser.to_string filtered in
    let re_parsed = Diff_parser.parse filtered_text in
    (check int) "one fewer file" (file_count - 1) (List.length re_parsed);
    List.iter
      (fun (fd : Diff_parser.file_diff) ->
        (check bool) "filtered path absent" true (not (String.equal fd.path first_path)))
      re_parsed
  end

(** {2 Test runner} *)

let () =
  run "diff_parser"
    [
      ( "basic_parsing",
        [
          test_case "single hunk" `Quick test_basic_single_hunk;
          test_case "multi hunk" `Quick test_multi_hunk;
          test_case "multi file" `Quick test_multi_file;
        ] );
      ( "position_mapping",
        [
          test_case "single hunk positions" `Quick test_position_mapping_single_hunk;
          test_case "multi hunk positions" `Quick test_position_mapping_multi_hunk;
          test_case "position to line" `Quick test_position_to_line;
        ] );
      ( "edge_cases",
        [
          test_case "empty diff" `Quick test_empty_diff;
          test_case "new file" `Quick test_new_file;
          test_case "deleted file" `Quick test_deleted_file;
          test_case "renamed file" `Quick test_renamed_file;
          test_case "binary file in diff" `Quick test_binary_file_in_diff;
          test_case "no newline at end marker" `Quick test_no_newline_at_end_marker;
          test_case "permission-only change" `Quick test_permission_only_change;
          test_case "unicode content" `Quick test_unicode_content;
          test_case "very long hunk positions" `Quick test_very_long_hunk_positions;
          test_case "continuous positions across hunks" `Quick test_multiple_hunks_continuous_positions;
        ] );
      "filtering", [ test_case "filter paths" `Quick test_filter_paths ];
      ( "metrics",
        [
          test_case "estimate tokens" `Quick test_estimate_tokens;
          test_case "total lines single" `Quick test_total_lines;
          test_case "total lines multi hunk" `Quick test_total_lines_multi_hunk;
        ] );
      ( "to_string",
        [
          test_case "roundtrip single hunk" `Quick test_to_string_roundtrip;
          test_case "roundtrip real diff" `Quick test_to_string_multi_file_roundtrip;
          test_case "preserves filter" `Quick test_to_string_preserves_filter;
        ] );
    ]
