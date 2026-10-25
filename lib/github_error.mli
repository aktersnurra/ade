(** Provider failures shared by the decoder and top-level error reporting. *)
type t =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string
  | Signing_failed of string
  | Scope_exceeded of string

val to_string : t -> string
