type review_metadata = {
  change_title : string;
  change_description : string;
  file_contents : (string * string) list;
  fetch_file : Review_job.fetch_file;
}

module type S = sig
  val name : string

  val run :
    ctx:Context.t ->
    repo_url:string ->
    config:Config_types.config ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:review_metadata ->
    (Review_types.finding list * Cost_tracking.agent_cost list) Lwt.t
end
