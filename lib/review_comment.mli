(** Platform-neutral inline review comments.

    Source and sink adapters should convert this type to platform-specific API
    payloads. The core review path should not depend on GitHub comment request
    types. *)

(** Which side of a diff the comment is anchored to. *)
type side =
  | Left
  | Right

(** A single inline review comment anchored to a changed file. *)
type t = {
  path : string;
  line : int;
  side : side;
  start_line : int option;
  start_side : side option;
  body : string;
}
