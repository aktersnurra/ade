(** Bringing an agent's work back from a clone workbench.

    A clone mount gives the guest a read-only repository and an [/outbox]. The
    agent clones into [/workspace/NAME] on its own disk; this module asks the
    guest to write a git bundle of its branches into the outbox, validates the
    bundle on the host, and fetches it into the user's repository as
    [refs/remotes/agents/*].

    Only the bundle crosses. Fetching straight from the guest's clone would run
    [upload-pack] inside a repository the guest controls, with the guest's
    config and hooks in reach; a bundle is data. The user's branches, working
    tree and config are never touched. *)

val run :
  smolvm:Smolvm.t ->
  runner:Process_runner.t ->
  git:string ->
  paths:State_paths.t ->
  Creation_manifest.t ->
  repo:string option ->
  (string list, Ade_error.t) result
(** Pull every clone mount, or just [repo]. The machine must be running. Returns
    the names pulled. [git] is an absolute path. Targets come only from the
    recorded creation manifest, never a re-resolved declaration. The caller
    holds the workbench lock for the entire export and import. *)
