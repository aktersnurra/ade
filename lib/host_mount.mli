(** Host-side policy for declared mounts.

    {!Declaration} checks what can be checked without touching the host. This
    module resolves each host path on the machine that will run the workbench
    and refuses the ones that would hand the guest more than the user meant:
    the home directory or an ancestor of it, credential and configuration
    stores, ADE's own state and declarations, and writable version-control
    metadata. *)

type resolved = private {
  source : string;
  guest : string;
  read_only : bool;
}
(** [source] is the canonical host path, with every symlink resolved, so the
    path the runtime mounts is the path that was checked. *)

type policy = { home : string; protected : string list }

val default_policy : home:string -> state_root:string -> declarations_dir:string -> policy
(** Protects, on both Linux and macOS, everything that holds credentials or
    host configuration under [home], plus ADE's state root and declarations.
    A writable mount of the declarations would let the guest widen its own
    allowlist. *)

val resolve : policy -> Declaration.mount -> (resolved, Ade_error.t) result

val resolve_all :
  policy -> Declaration.mount list -> (resolved list, Ade_error.t) result

type repo = private { name : string; source : string }
(** A declared repository at its canonical host path, checked by the same
    policy as a mount and known to contain [.git]. *)

val resolve_repo : policy -> Declaration.repo -> (repo, Ade_error.t) result

val for_declaration :
  paths:State_paths.t -> Declaration.t -> (resolved list, Ade_error.t) result
(** Resolves a declaration's mounts under the default policy for this host,
    followed by the inbox ([/inbox], read-only) and the outbox ([/outbox],
    writable) every workbench has. Creates no directories. *)

val repos_for_declaration :
  paths:State_paths.t -> Declaration.t -> (repo list, Ade_error.t) result
(** Resolves a declaration's repositories under the default policy for this
    host, in declaration order. *)

val volume_spec : resolved -> string
(** The runtime's [HOST:GUEST[:ro]] form. *)
