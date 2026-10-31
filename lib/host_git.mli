(** Git on the host, run against the user's repositories.

    It runs with no user or system config and no prompts. The repository's
    own config still applies, since it is the user's, and the guest only ever
    sees bundles of it. *)

val run :
  runner:Process_runner.t -> git:string -> directory:string -> string list ->
  (unit, Ade_error.t) result
(** [git -C directory ARGS]; a nonzero exit is an error carrying stderr. *)

val output :
  runner:Process_runner.t -> git:string -> directory:string -> string list ->
  (Process_runner.output, Ade_error.t) result
(** As {!run}, but the output is returned whatever the status. *)
