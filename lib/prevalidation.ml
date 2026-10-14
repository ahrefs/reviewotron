type verdict =
  | Confirmed
  | Rejected
  | Forwarded
  | Unanswered

type snapshot = {
  plugin : string;
  candidates : Yojson.Basic.t list;
}

type call = {
  plugin : string;
  validator : string;
  attempt : string;
  candidates : Yojson.Basic.t list;
  verdicts : (int * verdict) list;
  costs : Cost_tracking.agent_cost list;
}

type t = {
  snapshots : snapshot list;
  calls : call list;
}

type recorder = t -> unit

let empty = { snapshots = []; calls = [] }
let snapshot ~plugin ~candidates = { empty with snapshots = [ { plugin; candidates } ] }

let call ~plugin ~validator ~attempt ~candidates ~verdicts ~costs =
  { empty with calls = [ { plugin; validator; attempt; candidates; verdicts; costs } ] }

let merge left right = { snapshots = left.snapshots @ right.snapshots; calls = left.calls @ right.calls }

let candidate_key candidate =
  candidate |> Yojson.Basic.to_string |> Digestif.SHA256.digest_string |> Digestif.SHA256.to_hex

let verdict_to_string = function
  | Confirmed -> "confirmed"
  | Rejected -> "rejected"
  | Forwarded -> "forwarded"
  | Unanswered -> "unanswered"

let candidate_to_json candidate = `Assoc [ "candidate_key", `String (candidate_key candidate); "candidate", candidate ]

let call_candidate_to_json verdicts candidate_id candidate =
  let verdict =
    match List.assoc_opt candidate_id verdicts with
    | Some verdict -> verdict
    | None -> Unanswered
  in
  `Assoc
    [
      "candidate_id", `Int candidate_id;
      "candidate_key", `String (candidate_key candidate);
      "verdict", `String (verdict_to_string verdict);
      "candidate", candidate;
    ]

let snapshot_to_json (snapshot : snapshot) =
  `Assoc [ "plugin", `String snapshot.plugin; "candidates", `List (List.map candidate_to_json snapshot.candidates) ]

let call_to_json (call : call) =
  `Assoc
    [
      "plugin", `String call.plugin;
      "validator", `String call.validator;
      "attempt", `String call.attempt;
      "candidates", `List (List.mapi (call_candidate_to_json call.verdicts) call.candidates);
      "costs", `List (List.map Cost_tracking.agent_cost_to_json call.costs);
    ]

let to_json evidence =
  `Assoc
    [
      "schema", `Int 1;
      "snapshots", `List (List.map snapshot_to_json evidence.snapshots);
      "calls", `List (List.map call_to_json evidence.calls);
    ]
