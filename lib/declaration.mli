(** Host-owned workbench declarations.

    A declaration is parsed once from TOML into a validated value. Unknown keys
    are rejected rather than ignored, so host configuration drift is visible
    instead of silently discarded. *)

type network =
  | Sealed
  | Public
  | Allowlisted of { hosts : string list; cidrs : string list }

type ssh =
  | Disabled
  | Dedicated_agent of { key_ref : string }

type resources = {
  cpus : int;
  memory_mib : int;
  overlay_gib : int;
  workspace_gib : int;
}

type backup = { directory : string; keep : int }

type t

val load : string -> (t, Ade_error.t) result
val name : t -> Workbench_name.t
val image : t -> string
val smolfile : t -> string
val resources : t -> resources
val network : t -> network
val ssh : t -> ssh
val docker_enabled : t -> bool
val herdr_enabled : t -> bool
val backup : t -> backup

val digest_hex : t -> string
(** SHA-256 over a canonical rendering of the declaration.

    Ordering-insensitive fields (allowlist hosts and CIDRs) are sorted first, so
    a pure reordering is not reported as drift. Names and paths are never
    normalized. *)
