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

type mount_mode = Read_only | Read_write

type mount = { host : string; guest : string; mode : mount_mode }
(** A host directory made visible in the guest. [host] is as written, which may
    start with [~/]; {!Host_mount} resolves and polices it on the host. [guest]
    is validated here: absolute, in normal form, clear of reserved guest paths
    and of every other mount. *)

type t

val load : string -> (t, Ade_error.t) result

val path : t -> string
(** The file this declaration was loaded from. *)

val name : t -> Workbench_name.t
val image : t -> image

val image_digest : t -> string
(** The pinned digest, whichever form the image takes. Drift comparison and the
    declaration digest use this, so moving an image between a registry and a
    local artifact is not a change of identity. *)
val resources : t -> resources
val network : t -> network
val ssh : t -> ssh
val docker_enabled : t -> bool
val herdr_enabled : t -> bool
val backup : t -> backup

val mounts : t -> mount list
(** Declared mounts, in declaration order. Nothing is mounted unless declared,
    and a mount is read-only unless it says [mode = "rw"]. *)

val github_credential : t -> Otoml.t option
(** The raw [[credentials.github]] table, if declared. Left unparsed here so
    the credential module owns its own schema; Declaration only decides whether
    one was given. *)

val digest_hex : t -> string
(** SHA-256 over a canonical rendering of the declaration.

    Ordering-insensitive fields (allowlist hosts and CIDRs) are sorted first, so
    a pure reordering is not reported as drift. Names and paths are never
    normalized. *)
