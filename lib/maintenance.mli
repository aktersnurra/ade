(** Workspace backup, restore, reimage, pack and destroy.

    These are the operations that can destroy data, so each is expressed as an
    explicit sequence over the runtime with its irreversible steps ordered
    behind verification. *)

type outcome = {
  performed : string list;  (** the steps actually carried out, in order *)
  manifest_digest : string option;
}

type restore_mode =
  | Replace_workspace
      (** overwrite the target's workspace; refused unless the caller asked *)
  | Into_new_machine of Workbench_name.t

val backup :
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  declaration:Declaration.t ->
  destination:string ->
  (outcome, Ade_error.t) result
(** Export and validate /workspace only, then restore the source's original
    running or stopped state. Excludes root overlay, Docker state, caches,
    Herdr runtime state and installed secrets. *)

val restore :
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  declaration:Declaration.t ->
  archive:string ->
  mode:restore_mode ->
  (outcome, Ade_error.t) result

val reimage :
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  declaration:Declaration.t ->
  force_quiesce:bool ->
  (outcome, Ade_error.t) result
(** Reconstruct trusted guest state while preserving validated workspace data.

    The old machine is never deleted until a complete, parseable export has
    passed host validation. Every phase is journalled before the next
    destructive action, so an interrupted run resumes or reports that explicit
    recovery is required. A completed reimage leaves the workbench stopped. *)

val pack :
  smolvm:Smolvm.t ->
  declaration:Declaration.t ->
  output:string ->
  (outcome, Ade_error.t) result
(** A full machine artifact, refused while the source is running. Packs may
    contain root changes, Docker data, caches, login state and any credential
    guest code copied into persistent storage. *)

val destroy :
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  declaration:Declaration.t ->
  request:Destroy.request ->
  backup_destination:string option ->
  (outcome, Ade_error.t) result
