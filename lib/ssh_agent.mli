(** One dedicated host SSH agent per running workbench.

    ADE does not put a private key in the guest. It starts an agent on the host,
    loads only that workbench's declared identity, and forwards the socket in.
    Removing the capability is unloading the agent, not revoking a key.

    Every process in the workbench can request signatures while the socket is
    forwarded. This is VM-level authority, not per-agent: the design is explicit
    that agents inside one workbench are mutually trusted, so the boundary is
    the workbench, not the process. *)

type t

val socket_path : t -> string
(** The host socket to forward as [SSH_AUTH_SOCK]. *)

val is_populated : t -> bool
(** Whether an identity has been loaded. A maintenance agent is deliberately
    empty. *)

val pid : t -> string

val of_record : socket:string -> pid:string -> populated:bool -> t
(** Rebuild a handle from what an earlier ADE process recorded, so the process
    that stops a workbench can stop the agent another process started. *)

type mode =
  | Populated
      (** A normal start: the declared identity is loaded and the workbench can
          sign. *)
  | Empty
      (** A bounded maintenance window. The agent exists so the socket is
          present, but holds no identity, so the export helper cannot sign
          anything with the workbench's key. *)

val start :
  ?runner:Process_runner.t ->
  paths:State_paths.t ->
  name:Workbench_name.t ->
  mode:mode ->
  identity:Secret.t option ->
  unit ->
  (t, Ade_error.t) result
(** Start the agent for one workbench.

    [identity] is required for {!Populated} and ignored for {!Empty}, so a
    maintenance window cannot accidentally load a key by passing one. *)

val stop : ?runner:Process_runner.t -> t -> (unit, Ade_error.t) result
(** Stop the agent and remove its socket. Called when the workbench stops, so
    the capability does not outlive the machine that had it. *)

val loaded_identities :
  ?runner:Process_runner.t -> t -> (int, Ade_error.t) result
(** How many identities the agent holds. Used to assert that a maintenance
    agent really is empty rather than assuming it. *)
