(** Host-owned workbench declarations.

    A declaration is parsed once from TOML into a validated value. Unknown keys
    are rejected rather than ignored, so host configuration drift is visible
    instead of silently discarded. *)

type image =
  | Registry of { reference : string }
      (** A registry reference pinned by digest, e.g. [name@sha256:...]. *)
  | Local_artifact of { path : string; digest : string }
      (** A tarball on the host, still pinned by the digest of the image it
          contains. A workbench built from a locally produced image cannot pull
          from a registry, and a sealed workbench has no network to pull with. *)

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
val image : t -> image

val image_digest : t -> string
(** The pinned digest, whichever form the image takes. Drift comparison and the
    declaration digest use this, so moving an image between a registry and a
    local artifact is not a change of identity. *)
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
