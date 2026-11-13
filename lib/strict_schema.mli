(** Requires every property, forbids extra ones and drops [default], at any depth. *)
val make : Jsonkit.Jsonschema.t -> Yojson.Basic.t
