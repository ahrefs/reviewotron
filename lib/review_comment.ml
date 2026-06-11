type side =
  | Left
  | Right

type t = {
  path : string;
  line : int;
  side : side;
  start_line : int option;
  start_side : side option;
  body : string;
}
