let is_object_schema fields =
  List.mem_assoc "properties" fields
  &&
  match List.assoc_opt "type" fields with
  | Some (`String "object") -> true
  | Some (`String _ | `Assoc _ | `Bool _ | `Float _ | `Int _ | `List _ | `Null) | None -> false

let property_names fields =
  match List.assoc_opt "properties" fields with
  | Some (`Assoc props) -> List.map (fun (name, _) -> `String name) props
  | Some (`Bool _ | `Float _ | `Int _ | `List _ | `Null | `String _) | None -> []

let set_field ~key ~value fields =
  match List.mem_assoc key fields with
  | true -> List.map (fun (k, v) -> if String.equal k key then k, value else k, v) fields
  | false -> fields @ [ key, value ]

let strict_object fields =
  match is_object_schema fields with
  | true ->
    fields
    |> set_field ~key:"required" ~value:(`List (property_names fields))
    |> set_field ~key:"additionalProperties" ~value:(`Bool false)
  | false -> fields

let rec make (schema : Jsonkit.Jsonschema.t) : Yojson.Basic.t =
  match schema with
  | `Assoc fields -> `Assoc (strict_object (List.filter_map keyword fields))
  | `List values -> `List (List.map make values)
  | (`Bool _ | `Float _ | `Int _ | `Null | `String _) as scalar -> scalar

and keyword (key, value) =
  match key, value with
  | "default", _ -> None
  | "properties", `Assoc props -> Some (key, `Assoc (List.map (fun (name, sub) -> name, make sub) props))
  | _ -> Some (key, make value)
