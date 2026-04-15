(** Security pipeline types — structured input/output for multi-agent security analysis.

    {2 JSON encoding}

    {b vuln_class} and {b confidence} are re-exported from {!Config_types} with
    the same lowercase-string serialization (e.g. ["injection"], ["high"]).  Their
    JSON Schema is a bare [{"type": "string"}] — identical to the approach used
    for {!Review_types.severity}.

    All other types use [[@@deriving json, jsonschema]] for both serialization and
    schema generation.  Variant types with payloads ({!sanitization_status},
    {!validation_verdict}) use melange-json-native's default array-tag encoding
    (e.g. [["Inadequate", "reason"]]). *)

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
    ]

(** {2 Triage types} *)

type region = {
  path : string; [@jsonschema.description "File path in the diff"]
  start_line : int;
  end_line : int;
}
[@@deriving json, jsonschema]

type triage_signal = {
  vuln_class : vuln_class;
  confidence : confidence;
  regions : region list;
  rationale : string;
}
[@@deriving json, jsonschema]

type triage_output = {
  signals : triage_signal list;
  language_hints : string list;
  skip_reason : string option; [@json.option]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** {2 Analysis types} *)

type source_evidence = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'HTTP request parameter id'"]
}
[@@deriving json, jsonschema]

type sink_evidence = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'String concatenation into SQL query'"]
}
[@@deriving json, jsonschema]

type flow_step = {
  path : string;
  line : int;
  description : string; [@jsonschema.description "e.g. 'Passed as argument to Db.execute'"]
}
[@@deriving json, jsonschema]

type sanitization_status =
  | Adequate
  | Inadequate of string
  | Missing
  | Unknown
[@@deriving json, jsonschema]

let sanitization_status_to_string : sanitization_status -> string = function
  | Adequate -> "Adequate"
  | Inadequate reason -> Printf.sprintf "Inadequate (%s)" reason
  | Missing -> "Missing"
  | Unknown -> "Unknown"

type candidate_finding = {
  vuln_class : vuln_class;
  source : source_evidence;
  sink : sink_evidence;
  flow : flow_step list;
  sanitization : sanitization_status;
  confidence : confidence;
  description : string;
  suggested_fix : string option; [@json.option]
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

type analysis_output = {
  findings : candidate_finding list;
  files_examined : string list;
  notes : string;
}
[@@deriving json, jsonschema] [@@json.allow_extra_fields]

(** {2 Validator types} *)

type validation_verdict =
  | Confirmed
  | Rejected of string
[@@deriving json, jsonschema]

type validated_finding = {
  finding : candidate_finding;
  verdict : validation_verdict;
  evidence_notes : string;
}
[@@deriving json, jsonschema]

type validator_output = { results : validated_finding list } [@@deriving json, jsonschema] [@@json.allow_extra_fields]

type curator_output = { updated_memory : string } [@@deriving json, jsonschema] [@@json.allow_extra_fields]

type memory_update = {
  timestamp : string;
  review_id : string;
  learnings : string list;
  stale_entries : string list;
}
[@@deriving json] [@@json.allow_extra_fields]
