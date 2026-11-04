(** Writing rules for model output that reviewotron posts to developers.

    Every agent whose text fields reach a pull request comment or the review
    body includes {!prompt_fragment} in its system prompt.  The word budgets in
    the fragment are instructions to the model only: reviewotron never shortens
    posted text to meet them. *)

(** System prompt section with per-field length budgets and plain-style rules
    (lead with the defect, name concrete identifiers, active voice, no hedging,
    no em dashes, no repetition across fields). *)
val prompt_fragment : string
