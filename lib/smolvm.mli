(** The only module that knows SmolVM command syntax.

    Every other module speaks in workbench terms. Keeping the syntax in one
    place is what makes the pinned runtime replaceable and auditable. *)

type state =
  | Absent  (** no machine with this name exists *)
  | Created  (** defined but never started *)
  | Stopped
  | Running

type t

val make : executable:string -> runner:Process_runner.t -> t

val state : t -> Workbench_name.t -> (state, Ade_error.t) result
val create : t -> Declaration.t -> (unit, Ade_error.t) result
val start : ?ssh_auth_sock:string -> t -> Workbench_name.t -> (unit, Ade_error.t) result
val stop : t -> Workbench_name.t -> (unit, Ade_error.t) result
val delete : t -> Workbench_name.t -> (unit, Ade_error.t) result

val exec :
  t -> Workbench_name.t -> string list -> (Process_runner.output, Ade_error.t) result

val exec_checked :
  t -> Workbench_name.t -> string list -> (unit, Ade_error.t) result
(** Run a guest command and fail on a nonzero exit.

    [exec] deliberately returns the output whatever the status, because a user
    command that fails is not an ADE error. A maintenance helper is different:
    if the export or restore helper fails, the transaction must stop rather
    than continue on the assumption that it worked. *)

val exec_with_stdin :
  t -> Workbench_name.t -> string list -> stdin:string ->
  (Process_runner.output, Ade_error.t) result
(** Run a guest command with a payload on stdin. Secret values travel this way
    rather than in argv, which any local process can read from the process
    table. *)

val attach : t -> Workbench_name.t -> command:string list -> (unit, Ade_error.t) result

val attach_volume :
  t -> Workbench_name.t -> host:string -> guest:string -> read_only:bool ->
  (unit, Ade_error.t) result
(** Attach a host directory to a stopped machine. Used only for the bounded
    maintenance mounts a reimage transaction needs; a maintenance mount never
    targets /workspace, which would hide the storage being exported. *)

val detach_volume :
  t -> Workbench_name.t -> guest:string -> (unit, Ade_error.t) result

val copy_to_guest :
  t -> Workbench_name.t -> source:string -> destination:string ->
  (unit, Ade_error.t) result
(** Copy one host file into the guest. Not the workspace transfer mechanism:
    an individual transfer is capped below 4 GiB. *)

val pack : t -> Workbench_name.t -> output:string -> (unit, Ade_error.t) result
(** Create a full machine artifact. Upstream requires a stopped source. *)

val parse_state : string -> (state, string) result
(** Exposed for tests: map one SmolVM state string onto the ADT. *)

val create_argv : Declaration.t -> string list
(** Exposed for tests: the exact argv used to create a machine. *)
