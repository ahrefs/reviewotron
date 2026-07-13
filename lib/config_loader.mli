(** Layered configuration loading for local CLI reviews. *)

(** Deep-merge [upper] over [lower]. Objects merge recursively; scalar and
    array values from [upper] replace lower values. *)
val deep_merge : Yojson.Basic.t -> Yojson.Basic.t -> Yojson.Basic.t

(** Merge JSON layers from lowest to highest precedence. *)
val merge_layers : Yojson.Basic.t list -> Yojson.Basic.t

(** Load the global, project, local, and optional inline local-review layers,
    then decode the merged object exactly once. *)
val load_local :
  root:string -> ?project_filename:string -> ?inline_json:string -> unit -> (Config_types.config, string) result

(** Apply local-review defaults and the explicit security opt-out. *)
val apply_local_plugin_defaults : no_security:bool -> Config_types.config -> Config_types.config
