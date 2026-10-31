(** Handing the user's repositories to the guest as git bundles.

    No repository is mounted. At every start the host writes a bundle of each
    one's [HEAD] and branches into the inbox, which the guest sees read-only
    at [/inbox]; the guest clones it into [/workspace/NAME] the first time and
    fetches it into [refs/remotes/host/*] after that, pruned, so those refs
    mirror the host's branches. The agents' own branches
    and working tree are never touched, and the guest sees committed history
    only: no working tree, untracked files or anything else on the host.
    Work comes back the other way through {!Pull}. *)

val sync :
  smolvm:Smolvm.t ->
  runner:Process_runner.t ->
  git:string ->
  paths:State_paths.t ->
  name:Workbench_name.t ->
  Host_mount.repo list ->
  (unit, Ade_error.t) result
(** Bundle every repository whose refs changed since the last sync, remove the
    bundles of repositories no longer declared, record what was handed over,
    then have the guest clone or fetch each one. The machine must be running.

    A host failure is an error, because it is the user's to fix. A guest
    failure is a warning on stderr and the sync goes on: the clone is the
    agents' own state, and failing would keep the user out of the workbench,
    since [exec] and [attach] start it too. A repository with no refs is
    skipped with a warning. *)

val recorded :
  paths:State_paths.t -> Workbench_name.t -> ((string * string) list, Ade_error.t) result
(** The repositories last handed to the guest, as [(name, host path)]; empty
    when none were. *)
