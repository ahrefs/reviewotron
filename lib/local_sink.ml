let render_comment (comment : Review_comment.t) =
  Printf.sprintf "#### `%s:%d`\n\n%s" comment.path comment.line comment.body

let render_comments = function
  | [] -> ""
  | comments ->
    let rendered = comments |> List.map render_comment |> String.concat "\n\n" in
    Printf.sprintf "\n\n### Inline comments\n\n%s" rendered

let render_markdown (report : Review_engine.report) = report.body ^ render_comments report.comments
