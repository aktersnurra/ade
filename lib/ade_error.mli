(** Structured, user-facing ADE failures.

    Errors keep the underlying cause so a report can name the real SmolVM or
    provider failure rather than a generic message. *)

type t =
  | Github_failed of Github_error.t
  | Rollback_failed of { cause : t; cleanup : t list }
      (** The original failure and failures releasing acquired resources. *)
  | Declaration_not_found of { path : string }
  | Declaration_invalid of { path : string; reason : string }
  | Workbench_name_invalid of { value : string; reason : string }
  | Runtime_unavailable of { executable : string }
  | Runtime_failed of { argv : string list; status : int; stderr : string }
  | Runtime_output_invalid of { context : string; reason : string }
  | Operation_refused of { operation : string; reason : string }
      (** A policy refusal, not a runtime failure: the user must supply
          something before the operation may proceed. *)

val to_string : t -> string
(** A single-line, secret-free description suitable for stderr. *)
