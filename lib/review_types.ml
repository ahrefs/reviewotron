(** Review types -- structured output from Claude code review via tool_use.

    {2 JSON encoding}

    Severity and category are open string enums: known values map to specific
    constructors, unknown values land in [Other of string].  JSON representation
    is a bare string (e.g. ["critical"], ["error-handling"]).  This encoding is
    incompatible with melange-json-native's derived variant format, so these two
    types have manual [to_json]/[of_json] (justified under PRD rule "no manual
    JSON unless impossible").

    Records ([finding], [review_output]) use [[@@deriving json, jsonschema]]. *)

open Melange_json.Primitives

(** {2 Severity} *)

type severity =
  | Critical
  | Warning
  | Suggestion
  | Nitpick
  | Praise
  | Other of string

let severity_to_string = function
  | Critical -> "critical"
  | Warning -> "warning"
  | Suggestion -> "suggestion"
  | Nitpick -> "nitpick"
  | Praise -> "praise"
  | Other s -> s

let severity_to_json sev = `String (severity_to_string sev)

let severity_of_json = function
  | `String "critical" -> Critical
  | `String "warning" -> Warning
  | `String "suggestion" -> Suggestion
  | `String "nitpick" -> Nitpick
  | `String "praise" -> Praise
  | `String s -> Other s
  | json -> Melange_json.of_json_error ~json "expected a string for severity"

let severity_jsonschema =
  `Assoc
    [
      "type", `String "string";
      ( "description",
        `String "Severity level for the finding. Prefer: critical, warning, suggestion, nitpick, or praise." );
    ]

(** {2 Finding category} *)

type finding_category =
  | Bug
  | Security
  | Performance
  | Style
  | Logic
  | Error_handling
  | Naming
  | Documentation
  | Other of string

let finding_category_to_string = function
  | Bug -> "bug"
  | Security -> "security"
  | Performance -> "performance"
  | Style -> "style"
  | Logic -> "logic"
  | Error_handling -> "error-handling"
  | Naming -> "naming"
  | Documentation -> "documentation"
  | Other s -> s

let finding_category_to_json cat = `String (finding_category_to_string cat)

let finding_category_of_json = function
  | `String "bug" -> Bug
  | `String "security" -> Security
  | `String "performance" -> Performance
  | `String "style" -> Style
  | `String "logic" -> Logic
  | `String "error-handling" -> Error_handling
  | `String "naming" -> Naming
  | `String "documentation" -> Documentation
  | `String s -> Other s
  | json -> Melange_json.of_json_error ~json "expected a string for finding_category"

let finding_category_jsonschema =
  `Assoc
    [
      "type", `String "string";
      ( "description",
        `String
          "Finding category. Prefer: bug, security, performance, style, logic, error-handling, naming, or \
           documentation." );
    ]

(** {2 Finding} *)

type finding = {
  path : string; [@jsonschema.description "File path relative to repo root"]
  line : int;
     [@jsonschema.description
       "Line number (1-based) in the new version of the file. Must be a line that actually appears in the diff; \
        findings without a specific changed line should not be emitted."]
  end_line : int option;
     [@json.option]
     [@jsonschema.description
       "Last line of a multi-line anchor for the finding. Prefer single-line anchors: only set end_line when the \
        finding is genuinely unintelligible without the range — e.g. a specific control-flow branch, a try/catch body, \
        or the few lines that carry the bug. Do NOT span an entire function. Both line and end_line MUST be copied \
        verbatim from the left column of the annotated diff, MUST both sit inside the same hunk, and end_line MUST be \
        strictly greater than line. Leave null for single-line findings."]
  severity : severity; [@jsonschema.description "Severity: critical, warning, suggestion, nitpick, or praise"]
  category : finding_category;
     [@jsonschema.description
       "Category: bug, security, performance, style, logic, error-handling, naming, documentation"]
  message : string;
     [@jsonschema.description
       "One-sentence summary of the defect and (when useful) the fix. Must read as a finished comment."]
  failure_scenario : string;
     [@json.default ""]
     [@jsonschema.description
       "Concrete failure scenario for machine-readable review output: describe the user/input/state, the execution \
        path, and the observable breakage or risk. Keep this grounded in evidence from the diff and fetched files; do \
        not include speculation."]
  suggested_fix : string option;
     [@json.option]
     [@jsonschema.description
       "Code suggestion that replaces only the flagged lines. Return raw code with correct indentation and no markdown \
        fences."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** {2 Review output} *)

type review_output = {
  summary : string; [@jsonschema.description "High-level summary of the review (2-4 sentences)"]
  findings : finding list; [@jsonschema.description "List of inline findings to post on changed files and lines"]
  overall_assessment : string; [@json.default ""] [@jsonschema.description "Brief overall quality assessment"]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]
