(** Host-owned workbench declarations.

    A declaration is parsed once from TOML into a validated value. Unknown keys
    are rejected rather than ignored, so host configuration drift is visible
    instead of silently discarded. *)

type image =
  | Registry of { reference : string }
      (** A registry reference, e.g. [name:tag]. A digest ([name@sha256:...])
          is optional but checked when present. *)
  | Local_artifact of { path : string; digest : string }
      (** A tarball on the host, still pinned by the digest of the image it
          contains. A workbench built from a locally produced image cannot pull
          from a registry, and a sealed workbench has no network to pull with. *)

type classifier = { model : string; api_key_ref : string }
(** An OpenRouter model that annotates refused requests for the user. *)

type network =
  | Sealed
  | Public
  | Allowlisted of { hosts : string list; cidrs : string list }
  | Proxied of { hosts : string list; proxy : string; classifier : classifier option }
      (** The machine may reach only [proxy] ([IPV4:PORT]), where ADE's egress
          proxy allows [hosts] ({!Egress.parse_pattern}) and refuses the rest.
          The hosts are read while the machine runs, so they are not fixed at
          creation. *)

type ssh =
  | Disabled
  | Dedicated_agent of { key_ref : Secret.t }

type resources = {
  cpus : int;
  memory_mib : int;
  overlay_gib : int;
  workspace_gib : int;
}

type mount_mode = Read_only | Read_write

type mount = { host : string; guest : string; mode : mount_mode }
(** A host directory made visible in the guest. [host] is as written, which may
    start with [~/]; {!Host_mount} resolves and polices it on the host. [guest]
    is validated here: absolute, in normal form, clear of reserved guest paths
    and of every other mount. *)

type repo = { host : string; name : string }
(** A host git repository handed to the guest as a bundle ({!Repo_sync}) and
    brought back as one ({!Pull}); it is never mounted. [host] is as written;
    {!Host_mount} resolves and polices it. [name] is the last component of
    [host], held to letters, digits, [.], [_] and [-], and unique. *)

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
val provision : t -> string option
(** The provisioning script's path, resolved against the directory of the
    declaration file. Never set on a sealed workbench. *)

val resources : t -> resources
val network : t -> network
val ssh : t -> ssh
val herdr_enabled : t -> bool

val mounts : t -> mount list
(** Declared mounts, in declaration order. Nothing is mounted unless declared,
    and a mount is read-only unless it says [mode = "rw"]. At most six fit:
    SmolVM boots eight, and every workbench has an inbox and an outbox. *)

val repos : t -> repo list
(** Declared repositories, in declaration order. They are synced at every
    start, so they are not part of {!creation_shape}. *)

val github_credential : t -> Github_credential.config option
(** Provider-owned parsing happens at declaration loading, before any effects. *)

val anthropic_api_key_ref : t -> string option
(** [[credentials.anthropic] api_key_ref], a secret reference such as
    ["pass:ade/work-anthropic"]. The key is installed into guest tmpfs at every
    start for Claude Code; it is never part of the declaration itself. *)

val creation_shape : t -> (string * string) list
(** What the machine is created with and keeps until it is deleted, as
    [(group, value)] pairs: ["image"], ["resources"], ["network"], ["ssh"] (only
    whether an agent is forwarded) and ["mounts"] (one pair per mount, as
    written). Settings applied at every start, such as the SSH key or Herdr, are
    left out, so changing them is not drift. *)

val digest_hex : t -> string
(** SHA-256 over a canonical rendering of the declaration.

    Ordering-insensitive fields (allowlist hosts and CIDRs) are sorted first, so
    a pure reordering is not reported as drift. Names and paths are never
    normalized. *)
