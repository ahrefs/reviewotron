open Devkit

let log = Log.from "security_memory"

let repo_slug = Review_job.repo_slug

let memory_path ~memory_dir ~repo_url = Filename.concat memory_dir (repo_slug repo_url ^ ".md")

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
