module Make (AI : Api.Agent_runner) = struct
  module Engine = Review_engine.Make (AI)

  let review_diff ~ctx ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () =
    match%lwt Local_source.prepare_review ~root ~repo_key ?change_key ~title ~description ~diff_path ~config () with
    | Error error -> Lwt.return (Error (Local_source.string_of_prepare_error error))
    | Ok Local_source.{ job; filtered_diff } ->
      let%lwt report = Engine.run_pr_review ~ctx ~job ~number:0 ~filtered_diff in
      Lwt.return (Ok (Local_sink.render_markdown report))
end
