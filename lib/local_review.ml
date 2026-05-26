module Make (AI : Api.Agent_runner) = struct
  module Engine = Review_engine.Make (AI)

  let run_prepared ~ctx Local_source.{ job; filtered_diff } =
    let%lwt report = Engine.run_pr_review ~ctx ~job ~number:0 ~filtered_diff in
    let state = Context.state ctx in
    State.record_change_review state ~repo_key:job.repo_key ~change_key:job.change_key ~review_costs:report.review_costs;
    State.save state;
    Lwt.return (Ok (Local_sink.render_markdown report))

  let review_diff ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () =
    match%lwt Local_source.prepare_review ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () with
    | Error error -> Lwt.return (Error (Local_source.string_of_prepare_error error))
    | Ok prepared -> run_prepared ~ctx prepared

  let review_diff_text ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_text ~config () =
    match%lwt
      Local_source.prepare_review_from_text ~root ~repo_key ?change_key ~title ~description ~diff_text ~config ()
    with
    | Error error -> Lwt.return (Error (Local_source.string_of_prepare_error error))
    | Ok prepared -> run_prepared ~ctx prepared
end
