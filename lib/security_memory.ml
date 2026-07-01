open Devkit

let log = Log.from "security_memory"

let repo_slug = Review_job.repo_slug

let log_context_prefix = function
  | None -> ""
  | Some context -> context ^ " "

let memory_path ~memory_dir ~repo_url = Filename.concat memory_dir (repo_slug repo_url ^ ".md")

let load ~log_context ~memory_dir ~repo_url =
  let log_prefix = log_context_prefix log_context in
  let path = memory_path ~memory_dir ~repo_url in
  try
    let content = Std.input_file ~bin:true path in
    let len = String.length content in
    if Int.equal len 0 then None
    else begin
      log#info "%sloaded security memory from %s (%d bytes)" log_prefix path len;
      Some content
    end
  with
  | Sys_error _ -> None
  | exn ->
    log#warn "%sunexpected error loading security memory from %s: %s" log_prefix path (Exn.str exn);
    None

let save ~log_context ~memory_dir ~repo_url ~content =
  let log_prefix = log_context_prefix log_context in
  let path = memory_path ~memory_dir ~repo_url in
  Files.mkdir_p memory_dir;
  try Files.save_as path (fun oc -> output_string oc content)
  with exn -> log#error "%sfailed to save security memory to %s: %s" log_prefix path (Exn.str exn)
