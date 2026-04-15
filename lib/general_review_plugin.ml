open Devkit

let log = Log.from "general_review_plugin"

module Make (AI : Api.Agent_runner) = struct
  let name = "general"

  let run_review ~ctx ~repo_url ~diff_text ~metadata =
    let config = Context.get_config ctx ~repo_url in
    let system = Review_prompt.system_prompt ?override:config.system_prompt_override () in
    let Review_plugin.{ pr_title; pr_description; file_contents; _ } = metadata in
    let input = Review_prompt.build_user_message ~diff:diff_text ~pr_title ~pr_description ~file_contents () in
    let agent_config : Agent_runner.agent_config =
      {
        name = "general_review";
        system_prompt = system;
        model_tier = Standard;
        output_schema = Review_types.review_output_jsonschema;
        max_steps = 1;
      }
    in
    let%lwt result = AI.run ~ctx ~repo_url ~model_id:config.model ~config:agent_config ~input () in
    match result with
    | Error _ as e -> Lwt.return e
    | Ok agent_result ->
    match Review_types.review_output_of_json agent_result.output with
    | review ->
      log#info "review agent: %d findings, summary length %d" (List.length review.findings)
        (String.length review.summary);
      Lwt.return (Ok review)
    | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse review output: %s" (Exn.str exn)))

  (* General review uses the raw diff text, not parsed file diffs. *)
  let run ~ctx ~repo_url ~diff:_ ~diff_text ~metadata =
    let%lwt result = run_review ~ctx ~repo_url ~diff_text ~metadata in
    match result with
    | Ok review -> Lwt.return review.findings
    | Error msg ->
      log#error "general review plugin failed: %s" msg;
      Lwt.return []
end
