(* Shared provider errors keep decoding failures structured across layers. *)
type t =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string
  | Signing_failed of string
  | Scope_exceeded of string

let to_string = function
  | Missing_private_key path -> "the GitHub App private key is not readable at " ^ path
  | Invalid_config reason -> "invalid GitHub credential configuration: " ^ reason
  | Exchange_failed { status; body } ->
      Printf.sprintf "GitHub refused the token exchange with status %d: %s" status (String.trim body)
  | Malformed_response reason -> "unreadable GitHub response: " ^ reason
  | Signing_failed reason -> "could not sign the GitHub App JWT: " ^ reason
  | Scope_exceeded reason -> "GitHub issued a token broader than requested, so it was discarded: " ^ reason
