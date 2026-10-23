(** Installing credential generations into guest tmpfs.

    ADE writes plaintext credentials only under [/run/ade/secrets], which is
    tmpfs and therefore gone on restart. A generation directory is immutable
    once written; activation is a symlink swap, so a reader sees either the
    whole previous generation or the whole new one.

    ADE cannot stop guest code copying a credential into persistent state.
    The guest's disk is therefore always treated as potentially
    secret-bearing. *)

type installed = {
  generation : Credential.generation;
  path : string;  (** the generation directory inside the guest *)
}

val secrets_root : string

val install :
  smolvm:Smolvm.t ->
  name:Workbench_name.t ->
  provider:Credential.provider ->
  value:string ->
  expires_at:float ->
  now:float ->
  previous:Credential.generation option ->
  (installed, Ade_error.t) result
(** Mint-time validation, then install and atomically activate.

    If validation fails the working generation stays active and is not revoked:
    a failed rotation must never leave a workbench with no usable credential. *)

val revoke :
  smolvm:Smolvm.t ->
  name:Workbench_name.t ->
  provider:Credential.provider ->
  (unit, Ade_error.t) result
(** Remove the active generation from the guest. Emergency revocation; the
    provider-side revocation, where supported, is the caller's concern. *)

val active_generation :
  smolvm:Smolvm.t -> name:Workbench_name.t -> (int option, Ade_error.t) result
(** The number of the generation the guest's [current] link points at, if
    any. A running workbench's next rotation must not reuse it. *)

val install_key :
  smolvm:Smolvm.t ->
  name:Workbench_name.t ->
  file:string ->
  value:string ->
  (unit, Ade_error.t) result
(** Write a long-lived key that ADE does not mint, such as a model API key, to
    [secrets_root/file] over stdin, replacing any earlier copy with a rename.
    It has no generations: nothing about it changes between starts. *)

val key_argv : file:string -> string list
(** Exposed for tests: the guest command used by {!install_key}. *)

val install_argv :
  provider:Credential.provider -> generation:int -> string list
(** Exposed for tests: the guest command used to write a generation. The
    credential value is never part of it. *)
