let already_reviewed_message ~repo_key ~change_key =
  Printf.sprintf "change %s in %s was already reviewed" change_key repo_key

let is_already_reviewed_message message = CCString.suffix ~suf:" was already reviewed" message

module Make (AI : Api.Agent_runner) = struct
  module Engine = Review_engine.Make (AI)

  let run_prepared_report ~ctx (job : Review_job.t) =
    let state = Context.state ctx in
    match State.is_change_reviewed state ~repo_key:job.repo_key ~change_key:job.change_key with
    | true -> Lwt.return (Error (already_reviewed_message ~repo_key:job.repo_key ~change_key:job.change_key))
    | false ->
      let%lwt report = Engine.run_review ~ctx ~job in
      State.record_change_review state ~repo_key:job.repo_key ~change_key:job.change_key
        ~review_costs:report.review_costs;
      State.save state;
      Lwt.return (Ok report)

  let run_prepared ~ctx prepared =
    let%lwt result = run_prepared_report ~ctx prepared in
    Lwt.return (Result.map Local_sink.render_markdown result)

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

  let review_diff_report ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () =
    match%lwt Local_source.prepare_review ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () with
    | Error error -> Lwt.return (Error (Local_source.string_of_prepare_error error))
    | Ok prepared -> run_prepared_report ~ctx prepared

  let review_diff_text_report ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_text ~config () =
    match%lwt
      Local_source.prepare_review_from_text ~root ~repo_key ?change_key ~title ~description ~diff_text ~config ()
    with
    | Error error -> Lwt.return (Error (Local_source.string_of_prepare_error error))
    | Ok prepared -> run_prepared_report ~ctx prepared
end
