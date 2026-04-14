(** ATD JSON adapters for backward-compatible config parsing. *)

(** Translates the legacy [gh_token] field into the new [auth] variant.
    This allows existing secrets files using [gh_token: "..."] to keep working
    alongside the new [auth: {... }] format. *)
module GH_token_to_auth_adapter : Atdgen_runtime.Json_adapter.S = struct
  let normalize (x : Yojson.Safe.t) =
    match x with
    | `Assoc ks ->
      `Assoc
        (List.map
           (fun (k, v) ->
             match k with
             | "gh_token" -> "auth", `List [ `String "GH_token"; v ]
             | _ -> k, v)
           ks)
    | _ -> x

  let restore (x : Yojson.Safe.t) = x
end
