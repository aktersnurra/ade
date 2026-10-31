(** Egress for proxied workbenches: approvals, the decision log, the proxy
    process and the guest's view of it.

    Allowed hosts come from three places, read for every request: the
    declaration's [network.hosts]; [NAME.allow] next to the declaration, for
    hosts allowed with [--always]; and a session list in ADE's state, for hosts
    allowed until the workbench next starts. All three are on the host. *)

val allow_file : Declaration.t -> string

val allowed_hosts : paths:State_paths.t -> Declaration.t -> string list

val is_allowed : paths:State_paths.t -> Declaration.t -> Egress.target -> bool
(** Persistent grants win; otherwise revocations override session grants,
    including wildcards and classifier approvals. *)

type scope =
  | Session  (** until the workbench next starts *)
  | Always  (** appended to [NAME.allow] *)

val allow :
  paths:State_paths.t -> Declaration.t -> host:string -> scope:scope -> (string, Ade_error.t) result
(** Allow a host pattern, returning the file it was written to. *)

val revoke : paths:State_paths.t -> Declaration.t -> host:string -> (bool, Ade_error.t) result
(** Take back a host allowed this session, by the user or the classifier, and
    refuse it until the workbench next starts or it is allowed again. [true]
    when the declaration or [NAME.allow] still lists it, which only the user
    can change. *)

type classify =
  target:Egress.target -> allowed:string list -> recent:string list -> Egress.verdict * string

val decider :
  paths:State_paths.t ->
  name:Workbench_name.t ->
  record:(Egress.event -> unit) ->
  allowed:(unit -> string list) ->
  classify:classify option ->
  Egress.target ->
  Egress_proxy.decision
(** How the proxy decides a destination no pattern allows: revoked hosts and
    names of an {!Egress.unusual_shape} are refused for the user; otherwise
    the classifier decides, once per target per proxy run. An [Allow] is
    recorded as an exact [host:port] in the session's auto-allowed list.
    Without a classifier everything is refused for the user. *)

val pending : paths:State_paths.t -> Declaration.t -> (Egress.pending list, Ade_error.t) result
val log : paths:State_paths.t -> Declaration.t -> (Egress.event list, Ade_error.t) result

val start : paths:State_paths.t -> Declaration.t -> (Egress_guard.binding option, Ade_error.t) result
(** Start the proxy and host guard, replace the binding, and clear session
    approvals. Return the binding SmolVM must use, or [None] unless proxied. *)

val mark_started : paths:State_paths.t -> Workbench_name.t -> (unit, Ade_error.t) result
(** Record successful mediated boot, so recovery cannot silently adopt an
    already-running machine launched before host mediation was enforced. *)

val ensure : paths:State_paths.t -> Declaration.t -> (unit, Ade_error.t) result
(** Start the proxy only if it is not running, keeping the session approvals:
    for a running machine whose proxy died. *)

val stop : paths:State_paths.t -> Workbench_name.t -> (unit, Ade_error.t) result
(** Stop the proxy if it runs, and remove its guard token. *)

val serve : paths:State_paths.t -> declaration_path:string -> (unit, Ade_error.t) result
(** Run the proxy in this process until it is killed. [ade net serve] is the
    only caller; {!start} runs it in the background. *)

val environment : Declaration.t -> (string * string) list
(** The proxy variables a guest process needs; empty unless proxied. *)

val guest_memory : workbench:string -> string
(** The Claude Code managed memory telling agents how a block is resolved. *)

val configure_guest :
  smolvm:Smolvm.t -> name:Workbench_name.t -> Declaration.t -> (unit, Ade_error.t) result
(** Write the proxy environment and the managed memory into a running guest.
    A no-op unless proxied. *)
