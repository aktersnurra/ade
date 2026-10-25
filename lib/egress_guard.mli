(** Host-only SmolVM mediated-egress v2 guard. A binding belongs to one
    workbench start and permits only that workbench's proxy endpoint. *)

type binding

val address : binding -> string
val token_hex : binding -> string
(** Host capability: pass only to SmolVM's environment, never to the guest,
    command-line arguments or logs. *)

val load : string -> (binding, string) result
val save : string -> binding -> (unit, string) result
(** Persist a binding atomically with mode 0600 so daemon recovery can reuse
    the address and token already held by the running VM. *)

val listen :
  ?binding:binding -> proxy:string -> unit -> (binding * Unix.file_descr, string) result
(** Bind host loopback, choosing a fresh port and random token unless recovering
    an existing binding. [proxy] comes from a validated declaration. Recovery
    refuses a changed proxy endpoint. *)

val serve : binding -> Unix.file_descr -> unit
(** Authenticate SmolVM's flow preludes, allow only the bound IPv4 TCP endpoint,
    and deny malformed, unauthenticated and other-destination requests. *)
