(** Minting a credential and installing it into a workbench.

    This is the piece that joins the provider modules to the installer: sign,
    exchange, validate, install, activate. Each step is separately tested; this
    module is the order they happen in. *)

type step =
  | Signed
  | Exchanged
  | Installed
  | Activated

val describe_step : step -> string

type rotation = {
  steps : step list;  (** completed in order, for a secret-free audit line *)
  generation : Credential.generation;
}

val rotate_github :
  ?http:(url:string -> bearer:string -> (int * string, string) result) ->
  ?runner:Process_runner.t ->
  smolvm:Smolvm.t ->
  name:Workbench_name.t ->
  config:Github_credential.config ->
  now:float ->
  previous:Credential.generation option ->
  unit ->
  (rotation, Ade_error.t) result
(** Mint a fresh installation token and install it.

    The App key never leaves the host and the minted token never becomes a
    return value: it is passed straight to the installer, which writes it to
    guest tmpfs. Nothing here returns a credential.

    A failure at any step leaves the previous generation active. A workbench
    with a working credential must never be left without one because a
    refresh failed. *)
