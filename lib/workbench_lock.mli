(** Per-workbench advisory lock.

    ADE serializes lifecycle and maintenance operations per workbench. The lock
    is deliberately not held for the duration of an interactive attachment. *)

type t

val acquire : State_paths.t -> Workbench_name.t -> (t, Ade_error.t) result
val release : t -> unit

val with_lock :
  State_paths.t -> Workbench_name.t -> (unit -> ('a, Ade_error.t) result) ->
  ('a, Ade_error.t) result
