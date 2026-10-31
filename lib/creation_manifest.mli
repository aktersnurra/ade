(** Versioned facts about the inputs actually used to create a machine.
    Unlike declarations, mount sources are resolved host identities. The
    decoder accepts only the current schema version; legacy records fail closed. *)
type t

val make : Declaration.t -> Host_mount.resolved list -> t
val name : t -> Workbench_name.t
val changes : recorded:t -> current:t -> string list
val encode : t -> string
val decode : string -> (t, string) result

val save : paths:State_paths.t -> t -> (unit, Ade_error.t) result
val load : paths:State_paths.t -> Workbench_name.t -> (t option, Ade_error.t) result
(** [None] means no record. Malformed, unsupported and unreadable records fail. *)
