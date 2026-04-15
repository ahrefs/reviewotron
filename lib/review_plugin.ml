type review_metadata = {
  pr_number : int;
  pr_title : string;
  pr_description : string;
  file_contents : (string * string) list;
}

module type S = sig
  val name : string

  val run :
    ctx:Context.t ->
    repo_url:string ->
    diff:Diff_parser.file_diff list ->
    diff_text:string ->
    metadata:review_metadata ->
    Review_types.finding list Lwt.t
end
