let rec deep_merge lower upper =
  match lower, upper with
  | `Assoc lower_fields, `Assoc upper_fields ->
    let merge_field fields (key, upper_value) =
      let value =
        match List.assoc_opt key fields with
        | Some lower_value -> deep_merge lower_value upper_value
        | None -> upper_value
      in
      (key, value) :: List.remove_assoc key fields
    in
    `Assoc (List.fold_left merge_field lower_fields upper_fields |> List.rev)
  | _, upper -> upper

let merge_layers layers = List.fold_left deep_merge (`Assoc []) layers

let read_json_file filepath =
  match Sys.file_exists filepath with
  | false -> Ok None
  | true ->
  match Yojson.Basic.from_string (Std.input_file ~bin:true filepath) with
  | json -> Ok (Some json)
  | exception exn -> Error (Printf.sprintf "failed to parse config from %s: %s" filepath (Printexc.to_string exn))

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some value when not (String.equal value "") -> Some value
  | Some _ | None -> None

let global_config_paths () =
  let home_path =
    Option.map (fun home -> Filename.concat home ".config/reviewotron/.reviewotron.json") (nonempty_env "HOME")
  in
  let xdg_path =
    Option.map
      (fun config_home -> Filename.concat config_home "reviewotron/.reviewotron.json")
      (nonempty_env "XDG_CONFIG_HOME")
  in
  List.filter_map Fun.id [ home_path; xdg_path ]
  |> List.fold_left (fun paths path -> if List.exists (String.equal path) paths then paths else paths @ [ path ]) []

let project_path ~root filename =
  match Filename.is_relative filename with
  | true -> Filename.concat root filename
  | false -> filename

let project_config_paths ~root ~project_filename =
  let project = project_path ~root project_filename in
  let local = Filename.concat root ".reviewotron.local.json" in
  match String.equal project local with
  | true -> [ project ]
  | false -> [ project; local ]

let load_local ~root ?(project_filename = ".reviewotron.json") ?inline_json () =
  let paths = global_config_paths () @ project_config_paths ~root ~project_filename in
  let rec load_paths acc = function
    | [] -> Ok (List.rev acc)
    | filepath :: rest ->
    match read_json_file filepath with
    | Error _ as error -> error
    | Ok None -> load_paths acc rest
    | Ok (Some json) -> load_paths (json :: acc) rest
  in
  let merged_result =
    match load_paths [] paths with
    | Error _ as error -> error
    | Ok layers ->
    match inline_json with
    | None -> Ok (merge_layers layers)
    | Some json ->
    match Yojson.Basic.from_string json with
    | inline -> Ok (merge_layers (layers @ [ inline ]))
    | exception exn -> Error (Printf.sprintf "failed to parse inline config JSON: %s" (Printexc.to_string exn))
  in
  Result.bind merged_result (fun merged ->
    try Ok (Config_types.config_of_json (Melange_json.of_string (Yojson.Basic.to_string merged)))
    with exn -> Error (Printf.sprintf "failed to decode local config: %s" (Printexc.to_string exn)))

let apply_local_plugin_defaults ~no_security (config : Config_types.config) =
  let security = { config.review_plugins.security with enabled = not no_security } in
  { config with review_plugins = { config.review_plugins with security } }
