(** Validation of untrusted workspace archives.

    A workspace export is produced inside a guest ADE does not trust. The
    manifest proves integrity only: that the bytes ADE validated are the bytes
    it restores. It does not qualify the workspace as safe to execute, and it
    cannot prove completeness against a guest that was already compromised. *)

type entry_kind =
  | Directory
  | Regular
  | Symlink of { target : string }
  | Hardlink of { target : string }

type entry = { path : string; kind : entry_kind; mode : int }

type rejection =
  | Absolute_path of string
  | Traversing_path of string
  | Hardlink_escapes_root of { path : string; target : string }
  | Device_node of string
  | Socket of string
  | Fifo of string
  | Setuid of string
  | Setgid of string
  | File_capability of string
  | Unexpected_owner of { path : string; uid : int; gid : int }

val describe_rejection : rejection -> string

val validate_entry : uid:int -> gid:int -> entry -> (entry, rejection) result
(** Reject or normalize one archive entry. *)

val validate_entries :
  uid:int -> gid:int -> entry list -> (entry list, rejection list) result

type manifest = { entry_count : int; total_bytes : int; digest_hex : string }

val manifest_of_directory : string -> (manifest, Ade_error.t) result
(** Walk a directory with lstat, never following symlinks, and summarize it. *)

val manifest_digest : manifest -> string
