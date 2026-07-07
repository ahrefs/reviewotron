(** Small string helpers shared across modules. *)

(** [contains_sub ~sub value] is [true] when [sub] occurs anywhere in [value]. *)
val contains_sub : sub:string -> string -> bool

(** [lower_contains ~sub value] is [contains_sub ~sub] applied to the
    lowercased [value]. [sub] is matched verbatim, so pass it lowercased. *)
val lower_contains : sub:string -> string -> bool
