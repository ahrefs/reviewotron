open Devkit

let log = Log.from "general_review_plugin"

(* Sized for a single-shot multi-finding review; tune here without touching
   call sites. *)
let general_review_thinking_budget = 4096

let build_agent_config ~system_prompt : Agent_runner.agent_config =
  {
    name = "general_review";
    system_prompt;
    model_tier = Standard;
    output_schema = Review_types.review_output_jsonschema;
    max_steps = 1;
    thinking_budget = Some general_review_thinking_budget;
  }

module Make (AI : Api.Agent_runner) = struct
  let name = "general"

  let run_review ~ctx ~repo_url ~(config : Config_types.config) ~diff_text ~metadata ?debug_dir () =
    let security_covered_elsewhere = config.review_plugins.security.enabled in
    let system = Review_prompt.system_prompt ?override:config.system_prompt_override ~security_covered_elsewhere () in
    let Review_plugin.{ pr_title; pr_description; file_contents; _ } = metadata in
    let input = Review_prompt.build_user_message ~diff:diff_text ~pr_title ~pr_description ~file_contents () in
    let agent_config = build_agent_config ~system_prompt:system in
    let%lwt result = AI.run ~ctx ~repo_url ~model_id:config.model ?debug_dir ~config:agent_config ~input () in
    match result with
    | Error _ as e -> Lwt.return (e, [])
    | Ok agent_result ->
      let cost = Cost_tracking.of_agent_result ~agent_name:"general_review" ~files_fetched:0 agent_result in
      (match Review_types.review_output_of_json agent_result.output with
      | review ->
        let counts = Hashtbl.create 8 in
        List.iter
          (fun (f : Review_types.finding) ->
            let key = Review_types.finding_category_to_string f.category in
            let n = try Hashtbl.find counts key with Not_found -> 0 in
            Hashtbl.replace counts key (n + 1))
          review.findings;
        let dist =
          Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts []
          |> List.sort (fun (a, _) (b, _) -> String.compare a b)
          |> List.map (fun (k, v) -> Printf.sprintf "%s=%d" k v)
          |> String.concat " "
        in
        log#info "review agent: %d findings (%s), summary length %d" (List.length review.findings) dist
          (String.length review.summary);
        Lwt.return (Ok review, [ cost ])
      | exception exn -> Lwt.return (Error (Printf.sprintf "failed to parse review output: %s" (Exn.str exn)), [ cost ]))

  let run ~ctx ~repo_url ~config ~diff:_ ~diff_text ~metadata =
    let%lwt result, costs = run_review ~ctx ~repo_url ~config ~diff_text ~metadata () in
    match result with
    | Ok review -> Lwt.return (review.findings, costs)
    | Error msg ->
      log#error "general review plugin failed: %s" msg;
      Lwt.return ([], costs)
end
