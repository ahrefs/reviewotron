open Devkit

let log = Log.from "security_memory"

let repo_slug url =
  let url =
    match String.split_on_char '/' url with
    | ("https:" | "http:") :: "" :: _host :: parts -> String.concat "/" parts
    | _ -> url
  in
  let url = Stre.rstrip ~chars:"/" url in
  let url = Option.default url (Filename.chop_suffix_opt ~suffix:".git" url) in
  String.map
    (function
      | '/' -> '-'
      | c -> c)
    url

let repo_file ~memory_dir ~repo_url ~ext = Filename.concat memory_dir (repo_slug repo_url ^ ext)

let memory_path ~memory_dir ~repo_url = repo_file ~memory_dir ~repo_url ~ext:".md"

let load ~memory_dir ~repo_url =
  let path = memory_path ~memory_dir ~repo_url in
  try
    let content = Std.input_file ~bin:true path in
    let len = String.length content in
    if Int.equal len 0 then None
    else begin
      log#info "loaded security memory from %s (%d bytes)" path len;
      Some content
    end
  with
  | Sys_error _ -> None
  | exn ->
    log#warn "unexpected error loading security memory from %s: %s" path (Exn.str exn);
    None

let save ~memory_dir ~repo_url ~content =
  let path = memory_path ~memory_dir ~repo_url in
  Files.mkdir_p memory_dir;
  try Files.save_as path (fun oc -> output_string oc content)
  with exn -> log#error "failed to save security memory to %s: %s" path (Exn.str exn)

(** {2 Memory update queue}

    Append-only JSONL queue for distributed safety.  Multiple reviewotron
    instances can append concurrently; the curator processes the queue
    serially. *)

let queue_path ~memory_dir ~repo_url = repo_file ~memory_dir ~repo_url ~ext:".queue"

let append_update ~memory_dir ~repo_url ~(update : Security_types.memory_update) =
  let path = queue_path ~memory_dir ~repo_url in
  Files.mkdir_p memory_dir;
  try
    let json = Melange_json.to_string (Security_types.memory_update_to_json update) in
    let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () ->
        output_string oc json;
        output_char oc '\n')
  with exn -> log#error "failed to append to memory queue %s: %s" path (Exn.str exn)

let read_updates ~memory_dir ~repo_url =
  let path = queue_path ~memory_dir ~repo_url in
  try
    let content = Std.input_file ~bin:true path in
    if Int.equal (String.length content) 0 then []
    else (
      let lines = String.split_on_char '\n' content in
      List.filter_map
        (fun line ->
          let trimmed = String.trim line in
          if Int.equal (String.length trimmed) 0 then None
          else
            begin try Some (Security_types.memory_update_of_json (Melange_json.of_string trimmed))
            with exn ->
              log#warn "skipping malformed queue entry in %s: %s" path (Exn.str exn);
              None
            end)
        lines)
  with
  | Sys_error _ -> []
  | exn ->
    log#warn "unexpected error reading memory queue %s: %s" path (Exn.str exn);
    []

let truncate_queue ~memory_dir ~repo_url =
  let path = queue_path ~memory_dir ~repo_url in
  try
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () -> ())
  with
  | Sys_error _ -> ()
  | exn -> log#error "failed to truncate memory queue %s: %s" path (Exn.str exn)
