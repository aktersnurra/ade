(** Credential generations and their installation into guest tmpfs.

    ADE writes plaintext credentials only to guest tmpfs under
    [/run/ade/secrets/generation-N], and switches a [current] symlink atomically
    after validation.

    ADE cannot prevent guest code from copying a credential into persistent
    state. The guest's disk is therefore always treated as potentially
    secret-bearing. *)

type provider =
  | Github

val provider_to_string : provider -> string

type generation = {
  number : int;
  provider : provider;
  expires_at : float;
  installed_at : float;
}

type validation_error =
  | Empty_value
  | Already_expired
  | Expiry_too_far of { seconds : float }

val describe_validation_error : validation_error -> string

val validate : now:float -> value:string -> expires_at:float ->
  (unit, validation_error) result
(** Validate a freshly minted credential before it is installed. If minting or
    validation fails, the working generation stays active and is not revoked. *)

val generation_path : root:string -> int -> string
val current_path : root:string -> string
val next_number : generation option -> int

type audit = {
  provider : provider;
  generation_number : int;
  expires_at : float;
  outcome : string;
}

val audit_line : audit -> string
(** A secret-free audit record. The credential value never appears. *)
