(** Structured, user-facing ADE failures.

    Errors keep the underlying cause so a report can name the real SmolVM or
    provider failure rather than a generic message. *)

type t =
  | Declaration_not_found of { path : string }
  | Declaration_invalid of { path : string; reason : string }
  | Workbench_name_invalid of { value : string; reason : string }
  | Runtime_unavailable of { executable : string }
  | Runtime_failed of { argv : string list; status : int; stderr : string }
  | Runtime_output_invalid of { context : string; reason : string }

val to_string : t -> string
(** A single-line, secret-free description suitable for stderr. *)
