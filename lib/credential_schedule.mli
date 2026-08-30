(** Bounded scheduling for credential rotation, without an ADE daemon.

    A user-level launchd timer invokes [ade credentials rotate --due]. Each
    invocation performs bounded work and exits. *)

type due_decision =
  | Skip_not_running
      (** A stopped workbench needs no active generation: start, attach and exec
          install one before starting dependent agents. *)
  | Skip_healthy
  | Rotate

val decide :
  now:float ->
  margin_seconds:float ->
  running:bool ->
  generation:Credential.generation option ->
  due_decision

val describe : due_decision -> string

val launchd_plist : label:string -> ade_path:string -> interval_seconds:int -> string
(** A user-level agent that runs one bounded rotation pass on an interval. *)
