(** Security pipeline types — structured input/output for multi-agent security analysis.

    {2 JSON encoding}

    All enum-like variants ({!vuln_class}, {!confidence}, {!sanitization_status},
    {!validation_verdict}) use lowercase-string JSON encoding (e.g. ["injection"],
    ["high"], ["inadequate"], ["rejected"]) with schemas of the form
    [{"type":"string","enum":[...]}].  This is the only variant encoding that
    Anthropic's structured-output subset accepts natively — array-tag encodings
    emit [prefixItems]/[maxItems]/[minItems>1] keywords that Anthropic rejects.

    Record types use [[@@deriving json, jsonschema]].  Free-form reasoning that
    would otherwise live in variant payloads (e.g. why sanitization is inadequate,
    why a finding was rejected) belongs in the existing prose fields
    ([description], [evidence_notes]). *)

open Melange_json.Primitives

(** {2 Re-exported enumerations} *)

type vuln_class = Config_types.vuln_class =
  | Injection
  | Xss
  | Command_injection
  | Authn
  | Authz
  | Ssrf

let vuln_class_to_string = Config_types.vuln_class_to_string
let vuln_class_to_json = Config_types.vuln_class_to_json
let vuln_class_of_json = Config_types.vuln_class_of_json
let vuln_class_jsonschema =
  `Assoc
    [
      "type", `String "string";
      "enum", `List (List.map (fun vc -> `String (Config_types.vuln_class_to_string vc)) Config_types.all_vuln_classes);
      ( "description",
        `String "Security vulnerability class to analyze: injection, xss, command_injection, authn, authz, or ssrf." );
    ]

type confidence = Config_types.confidence =
  | High
  | Medium
  | Low

let confidence_to_string = Config_types.confidence_to_string
let confidence_to_json = Config_types.confidence_to_json
let confidence_of_json = Config_types.confidence_of_json
let confidence_jsonschema =
  `Assoc
    [
      "type", `String "string";
      "enum", `List (List.map (fun c -> `String (Config_types.confidence_to_string c)) Config_types.all_confidences);
      "description", `String "Confidence score for the signal or finding: high, medium, or low.";
    ]

(** {2 Triage types} *)

type region = {
  path : string; [@jsonschema.description "File path in the diff"]
  start_line : int; [@jsonschema.description "First line in the diff hunk for this region"]
  end_line : int; [@jsonschema.description "Last line in the diff hunk for this region"]
}
[@@deriving json, jsonschema]

type triage_signal = {
  vuln_class : vuln_class;
     [@jsonschema.description "Vulnerability class that this signal should route to for deeper analysis"]
  confidence : confidence; [@jsonschema.description "How likely this signal represents a real vulnerability"]
  regions : region list; [@jsonschema.description "Diff regions that contain the suspicious code pattern"]
  rationale : string; [@jsonschema.description "Brief explanation of why these regions were flagged"]
}
[@@deriving json, jsonschema]

type triage_output = {
  signals : triage_signal list;
     [@jsonschema.description "Candidate security signals produced by triage; empty when nothing relevant is found"]
  language_hints : string list;
     [@jsonschema.description "Programming languages detected in changed files, e.g. OCaml, Python, JavaScript"]
  skip_reason : string option;
     [@json.option] [@jsonschema.description "Why triage emitted no signals; null when signals are present"]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** {2 Analysis types} *)

type source_evidence = {
  path : string; [@jsonschema.description "File path of the source"]
  line : int; [@jsonschema.description "Line number where user-controlled data enters"]
  description : string; [@jsonschema.description "e.g. 'HTTP request parameter id'"]
}
[@@deriving json, jsonschema]

type sink_evidence = {
  path : string; [@jsonschema.description "File path of the sink"]
  line : int; [@jsonschema.description "Line number where dangerous operation occurs"]
  description : string; [@jsonschema.description "e.g. 'String concatenation into SQL query'"]
}
[@@deriving json, jsonschema]

type flow_step = {
  path : string; [@jsonschema.description "File path for this data-flow step"]
  line : int; [@jsonschema.description "Line number for this data-flow step"]
  description : string; [@jsonschema.description "e.g. 'Passed as argument to Db.execute'"]
}
[@@deriving json, jsonschema]

type sanitization_status =
  | Adequate
  | Inadequate
  | Missing
  | Unknown

let sanitization_status_to_string = function
  | Adequate -> "adequate"
  | Inadequate -> "inadequate"
  | Missing -> "missing"
  | Unknown -> "unknown"

let all_sanitization_statuses = [ Adequate; Inadequate; Missing; Unknown ]

let sanitization_status_to_json status = `String (sanitization_status_to_string status)

let sanitization_status_of_json = function
  | `String "adequate" -> Adequate
  | `String "inadequate" -> Inadequate
  | `String "missing" -> Missing
  | `String "unknown" -> Unknown
  | json -> Melange_json.of_json_error ~json "expected sanitization_status string"

let sanitization_status_jsonschema =
  `Assoc
    [
      "type", `String "string";
      "enum", `List (List.map (fun s -> `String (sanitization_status_to_string s)) all_sanitization_statuses);
      ( "description",
        `String
          "Sanitization assessment: adequate, inadequate, missing, or unknown. When inadequate or unknown, explain the \
           reason in the finding's description field." );
    ]

type candidate_finding = {
  vuln_class : vuln_class; [@jsonschema.description "Vulnerability class for this candidate finding"]
  source : source_evidence; [@jsonschema.description "Concrete user-controlled source evidence"]
  sink : sink_evidence; [@jsonschema.description "Concrete dangerous sink evidence"]
  flow : flow_step list; [@jsonschema.description "Ordered source-to-sink data-flow steps with evidence"]
  sanitization : sanitization_status;
     [@jsonschema.description "Whether sanitization exists and whether it is adequate for this context"]
  confidence : confidence; [@jsonschema.description "Confidence that this candidate is a true vulnerability"]
  description : string;
     [@jsonschema.description "Concise vulnerability explanation tied to the provided source/sink/flow evidence"]
  suggested_fix : string option;
     [@json.option]
     [@jsonschema.description
       "Optional fix snippet that replaces the vulnerable lines. Return raw code with correct indentation and no \
        markdown fences."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

type analysis_output = {
  findings : candidate_finding list;
     [@jsonschema.description "Candidate vulnerabilities discovered in this analysis pass"]
  files_examined : string list;
     [@jsonschema.description "Files inspected from the diff and via get_file_content tool calls"]
  notes : string; [@jsonschema.description "Additional observations for this vulnerability class"]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** {2 Validator types} *)

type validation_verdict =
  | Confirmed
  | Rejected

let validation_verdict_to_string = function
  | Confirmed -> "confirmed"
  | Rejected -> "rejected"

let all_validation_verdicts = [ Confirmed; Rejected ]

let validation_verdict_to_json verdict = `String (validation_verdict_to_string verdict)

let validation_verdict_of_json = function
  | `String "confirmed" -> Confirmed
  | `String "rejected" -> Rejected
  | json -> Melange_json.of_json_error ~json "expected validation_verdict string"

let validation_verdict_jsonschema =
  `Assoc
    [
      "type", `String "string";
      "enum", `List (List.map (fun v -> `String (validation_verdict_to_string v)) all_validation_verdicts);
      ( "description",
        `String
          "Validation outcome: confirmed, or rejected. When rejected, explain the reason in the evidence_notes field."
      );
    ]

type validated_finding = {
  finding : candidate_finding; [@jsonschema.description "The candidate finding that was validated"]
  verdict : validation_verdict; [@jsonschema.description "Validation outcome: confirmed, or rejected with reason"]
  evidence_notes : string; [@jsonschema.description "Validator rationale and evidence supporting the verdict"]
}
[@@deriving json, jsonschema]

type validator_output = {
  results : validated_finding list;
     [@jsonschema.description "Validated findings to surface to developers after false-positive filtering"]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

type curator_output = {
  updated_memory : string;
     [@jsonschema.description
       "Full updated architectural brief for the repository. Contains only Architecture and Known Safe Patterns \
        sections; no file:line references."]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** Architectural observations passed to the memory curator.

    These are deliberately limited to information that describes the
    {e shape} of the repository — not any specific findings the review
    produced.  The type has no field for findings: the curator cannot
    record file:line claims because it is never told about them. *)
type architectural_observations = {
  language_hints : string list;
  reviewed_files : string list;
  vuln_class_distribution : (string * int) list;
}
