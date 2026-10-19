(** Convergent lifecycle operations.

    Every command states an intended end state and is safe to repeat. SmolVM
    remains authoritative for observed machine state; ADE compares that state to
    the host declaration and converges toward it. *)

type outcome =
  | Converged  (** the machine already satisfied the request *)
  | Changed  (** ADE performed work to satisfy the request *)

type t

val make : services:Boot.services -> smolvm:Smolvm.t -> paths:State_paths.t -> t

val create : t -> Declaration.t -> (outcome, Ade_error.t) result
(** Creating an absent machine creates it. Creating an existing machine succeeds
    only if it matches the declaration; otherwise it reports drift. *)

val start : t -> Declaration.t -> (outcome, Ade_error.t) result
val stop : t -> Declaration.t -> (outcome, Ade_error.t) result
val restart : t -> Declaration.t -> (outcome, Ade_error.t) result

val attach : t -> Declaration.t -> command:string list -> (unit, Ade_error.t) result
(** Attaching to a stopped machine starts it first. The lock is released before
    the interactive attachment begins. *)

val exec :
  t -> Declaration.t -> string list -> (Process_runner.output, Ade_error.t) result

type status = { name : string; state : Smolvm.state; drift : string option }

val status : t -> Declaration.t -> (status, Ade_error.t) result
