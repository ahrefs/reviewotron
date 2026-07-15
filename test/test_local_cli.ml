open Alcotest
open Reviewotron_lib

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc contents)

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Sys.remove path

let with_temp_dir f =
  let path = Filename.temp_file "reviewotron_local_cli_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let set_env name = function
  | Some value -> Unix.putenv name value
  | None -> ExtUnix.All.unsetenv name

let with_env name value f =
  let previous = Sys.getenv_opt name in
  set_env name value;
  Fun.protect ~finally:(fun () -> set_env name previous) f

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop index =
    match index + needle_length > haystack_length with
    | true -> false
    | false ->
    match String.equal (String.sub haystack index needle_length) needle with
    | true -> true
    | false -> loop (index + 1)
  in
  match Int.equal needle_length 0 with
  | true -> true
  | false -> loop 0

let selector_functions ~git_root =
  let discover_root ~cwd =
    match String.equal cwd git_root || String.starts_with ~prefix:(git_root ^ "/") cwd with
    | true -> Ok git_root
    | false -> Error "not a worktree"
  in
  let infer_base ~root:_ ~explicit:_ = Ok "origin/main" in
  let diff_against_base ~root:_ ~base:_ = Ok "diff --git a/a.ml b/a.ml\n" in
  let untracked_files ~root:_ = Ok [] in
  discover_root, infer_base, diff_against_base, untracked_files

let test_mode_directory_and_file_selection () =
  with_temp_dir (fun root ->
    let repo = Filename.concat root "repo" in
    let src = Filename.concat repo "src" in
    Unix.mkdir repo 0o755;
    Unix.mkdir src 0o755;
    let file = Filename.concat src "main.ml" in
    write_file file "let main = 1\n";
    let discover_root, infer_base, diff_against_base, untracked_files = selector_functions ~git_root:repo in
    let select requested_mode path =
      Local_mode.select_with ~discover_root ~infer_base ~diff_against_base ~untracked_files ~requested_mode ~path
        ~root:None ~base:None
    in
    (match select Local_mode.Auto src with
    | Ok (Local_mode.Review_diff { root = selected_root; base; _ }) ->
      check string "Git root" repo selected_root;
      check string "base" "origin/main" base
    | Ok (Local_mode.Review_path _) -> fail "directory in Git should use diff mode"
    | Error msg -> fail msg);
    match select Local_mode.Auto file with
    | Ok (Local_mode.Review_path { path = selected_path; project_root }) ->
      check string "file path" file selected_path;
      check string "project root" repo project_root
    | Ok (Local_mode.Review_diff _) -> fail "single file should use path mode"
    | Error msg -> fail msg)

let test_mode_outside_git_uses_path () =
  with_temp_dir (fun root ->
    let file = Filename.concat root "main.ml" in
    write_file file "let main = 1\n";
    let discover_root ~cwd:_ = Error "not a worktree" in
    let infer_base ~root:_ ~explicit:_ = Error "should not infer" in
    let diff_against_base ~root:_ ~base:_ = Error "should not diff" in
    let untracked_files ~root:_ = Error "should not list" in
    match
      Local_mode.select_with ~discover_root ~infer_base ~diff_against_base ~untracked_files
        ~requested_mode:Local_mode.Auto ~path:file ~root:None ~base:None
    with
    | Ok (Local_mode.Review_path { project_root; _ }) -> check string "path root" root project_root
    | Ok (Local_mode.Review_diff _) -> fail "non-Git file should use path mode"
    | Error msg -> fail msg)

let test_mode_empty_git_tree () =
  with_temp_dir (fun root ->
    Unix.mkdir (Filename.concat root "repo") 0o755;
    let repo = Filename.concat root "repo" in
    let discover_root ~cwd:_ = Ok repo in
    let infer_base ~root:_ ~explicit:_ = Ok "origin/main" in
    let diff_against_base ~root:_ ~base:_ = Ok "" in
    let untracked_files ~root:_ = Ok [] in
    match
      Local_mode.select_with ~discover_root ~infer_base ~diff_against_base ~untracked_files
        ~requested_mode:Local_mode.Auto ~path:repo ~root:None ~base:None
    with
    | Error msg -> check string "empty Git tree" "no changes to review" msg
    | Ok (Local_mode.Review_path _) -> fail "empty Git tree should not use path mode"
    | Ok (Local_mode.Review_diff _) -> fail "empty Git tree should fail")

let test_mode_missing_base_is_actionable () =
  with_temp_dir (fun root ->
    let repo = Filename.concat root "repo" in
    Unix.mkdir repo 0o755;
    let discover_root ~cwd:_ = Ok repo in
    let infer_base ~root:_ ~explicit =
      match explicit with
      | None -> Error "no candidate"
      | Some _ -> Error "bad explicit base"
    in
    let diff_against_base ~root:_ ~base:_ = Ok "diff" in
    let untracked_files ~root:_ = Ok [] in
    match
      Local_mode.select_with ~discover_root ~infer_base ~diff_against_base ~untracked_files
        ~requested_mode:Local_mode.Auto ~path:repo ~root:None ~base:None
    with
    | Error msg ->
      check bool "suggests --base" true (contains ~needle:"--base" msg);
      check bool "suggests path mode" true (contains ~needle:"--mode path" msg)
    | Ok (Local_mode.Review_path _) -> fail "Git directory without a base should not use path mode"
    | Ok (Local_mode.Review_diff _) -> fail "missing base should fail")

let test_untracked_files_are_synthesized () =
  with_temp_dir (fun root ->
    let src = Filename.concat root "src" in
    Unix.mkdir src 0o755;
    write_file (Filename.concat root "new.ml") "let new_value = 1\n";
    write_file (Filename.concat src "nested.ml") "let nested = 2\n";
    let run_git ~cwd:_ args =
      match args with
      | [ "ls-files"; "--others"; "--exclude-standard"; "-z" ] -> Ok "new.ml\000src/nested.ml\000"
      | _ -> Error "unexpected Git command"
    in
    match Local_git.untracked_files_with ~run_git ~root with
    | Error msg -> fail msg
    | Ok paths ->
      check (list string) "untracked paths" [ "new.ml"; "src/nested.ml" ] paths;
      let diff = Local_path.added_files_diff ~root ~paths in
      let file_diffs = Diff_parser.parse diff in
      check (list string) "synthesized paths" [ "new.ml"; "src/nested.ml" ]
        (List.map (fun (file_diff : Diff_parser.file_diff) -> file_diff.path) file_diffs);
      List.iter
        (fun (file_diff : Diff_parser.file_diff) ->
          match file_diff.status with
          | Diff_parser.Added -> ()
          | Diff_parser.Deleted | Diff_parser.Modified | Diff_parser.Renamed -> fail "untracked file was not added")
        file_diffs)

let test_config_layers_precedence_and_deep_merge () =
  with_temp_dir (fun root ->
    let home = Filename.concat root "home" in
    let xdg = Filename.concat root "xdg" in
    let project = Filename.concat root "project" in
    List.iter (fun path -> Unix.mkdir path 0o755) [ home; xdg; project ];
    let home_config_dir = Filename.concat home ".config" in
    let home_reviewotron_dir = Filename.concat home_config_dir "reviewotron" in
    let xdg_reviewotron_dir = Filename.concat xdg "reviewotron" in
    Unix.mkdir home_config_dir 0o755;
    Unix.mkdir home_reviewotron_dir 0o755;
    Unix.mkdir xdg_reviewotron_dir 0o755;
    write_file
      (Filename.concat home_reviewotron_dir ".reviewotron.json")
      {|{"model":"home","ignored_paths":["home"],"review_plugins":{"security":{"memory_max_tokens":1}}}|};
    write_file
      (Filename.concat xdg_reviewotron_dir ".reviewotron.json")
      {|{"model":"xdg","ignored_paths":["xdg"],"review_plugins":{"security":{"debug_artifacts":true}}}|};
    write_file
      (Filename.concat project ".reviewotron.json")
      {|{"model":"project","review_plugins":{"security":{"memory_max_tokens":2}}}|};
    write_file
      (Filename.concat project ".reviewotron.local.json")
      {|{"ignored_paths":["local"],"review_plugins":{"security":{"metrics_artifacts":true}}}|};
    with_env "HOME" (Some home) (fun () ->
      with_env "XDG_CONFIG_HOME" (Some xdg) (fun () ->
        match
          Config_loader.load_local ~root:project
            ~inline_json:{|{"model":"inline","review_plugins":{"security":{"memory_max_tokens":3}}}|} ()
        with
        | Error msg -> fail msg
        | Ok config ->
          check string "scalar precedence" "inline" config.model;
          check (list string) "array replacement" [ "local" ] config.ignored_paths;
          check int "nested override" 3 config.review_plugins.security.memory_max_tokens;
          check bool "nested value from XDG" true config.review_plugins.security.debug_artifacts;
          check bool "nested value from local" true config.review_plugins.security.metrics_artifacts)))

let test_config_array_replacement () =
  let lower = `Assoc [ "ignored_paths", `List [ `String "a"; `String "b" ] ] in
  let upper = `Assoc [ "ignored_paths", `List [ `String "c" ] ] in
  check string "arrays replace" {|{"ignored_paths":["c"]}|}
    (Yojson.Basic.to_string (Config_loader.deep_merge lower upper))

let test_invalid_config_layers_fail_clearly () =
  with_temp_dir (fun root ->
    let home = Filename.concat root "home" in
    let global_dir = Filename.concat home ".config" in
    let reviewotron_dir = Filename.concat global_dir "reviewotron" in
    Unix.mkdir home 0o755;
    Unix.mkdir global_dir 0o755;
    Unix.mkdir reviewotron_dir 0o755;
    let global_path = Filename.concat reviewotron_dir ".reviewotron.json" in
    write_file global_path "{";
    let expect_error label result needle =
      match result with
      | Ok _ -> fail (label ^ " unexpectedly succeeded")
      | Error msg -> check bool label true (contains ~needle msg)
    in
    with_env "HOME" (Some home) (fun () ->
      with_env "XDG_CONFIG_HOME" None (fun () ->
        expect_error "invalid global" (Config_loader.load_local ~root ()) global_path));
    Sys.remove global_path;
    write_file (Filename.concat root ".reviewotron.json") "{";
    expect_error "invalid project" (Config_loader.load_local ~root ()) (Filename.concat root ".reviewotron.json");
    Sys.remove (Filename.concat root ".reviewotron.json");
    expect_error "invalid inline" (Config_loader.load_local ~root ~inline_json:"{" ()) "inline config JSON")

let test_no_security_overrides_layered_config () =
  with_temp_dir (fun root ->
    match Config_loader.load_local ~root ~inline_json:{|{"review_plugins":{"security":{"enabled":false}}}|} () with
    | Error msg -> fail msg
    | Ok config ->
      let disabled = Config_loader.apply_local_plugin_defaults ~no_security:true config in
      let enabled = Config_loader.apply_local_plugin_defaults ~no_security:false config in
      check bool "--no-security wins" false disabled.review_plugins.security.enabled;
      check bool "local default enables security" true enabled.review_plugins.security.enabled)

let test_with_env_restores_unset_variable () =
  let name = "REVIEWOTRON_LOCAL_CLI_TEST_UNSET" in
  let previous = Sys.getenv_opt name in
  ExtUnix.All.unsetenv name;
  Fun.protect
    ~finally:(fun () -> set_env name previous)
    (fun () ->
      with_env name (Some "set") (fun () ->
        check (option string) "variable set in scope" (Some "set") (Sys.getenv_opt name));
      check bool "variable restored to unset" true (Option.is_none (Sys.getenv_opt name)))

let () =
  run "local_cli"
    [
      ( "mode",
        [
          test_case "directory and file selection" `Quick test_mode_directory_and_file_selection;
          test_case "outside Git uses path" `Quick test_mode_outside_git_uses_path;
          test_case "empty Git tree" `Quick test_mode_empty_git_tree;
          test_case "missing base is actionable" `Quick test_mode_missing_base_is_actionable;
          test_case "untracked files are synthesized" `Quick test_untracked_files_are_synthesized;
        ] );
      ( "config",
        [
          test_case "layers have precedence and deep merge" `Quick test_config_layers_precedence_and_deep_merge;
          test_case "arrays replace" `Quick test_config_array_replacement;
          test_case "invalid layers fail clearly" `Quick test_invalid_config_layers_fail_clearly;
          test_case "no-security overrides config" `Quick test_no_security_overrides_layered_config;
        ] );
      "environment", [ test_case "with_env restores unset variables" `Quick test_with_env_restores_unset_variable ];
    ]
