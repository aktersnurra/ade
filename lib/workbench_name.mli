(** Workbench names that are safe to use as SmolVM machine names and path
    components.

    Parsing happens once, at the boundary. A value of type [t] is always a name
    ADE may pass to the runtime and embed in a host path. *)

type t

type error =
  | Empty
  | Invalid_character of char
  | Too_long of int

val of_string : string -> (t, error) result
val to_string : t -> string
val error_reason : error -> string
val compare : t -> t -> int
