(** Where ADE keeps its own host state.

    ADE stores only what it needs: per-workbench locks, active transaction
    journals, backups and secret-free credential metadata. It keeps no parallel
    database of SmolVM machines. *)

type t

val make : ?root:string -> unit -> t
(** [root] defaults to [$ADE_STATE_ROOT], then
    [$XDG_STATE_HOME/ade], then [~/.local/state/ade]. Tests always pass an
    explicit root so no test touches real user state. *)

val root : t -> string
val lock_file : t -> Workbench_name.t -> string
val journal_file : t -> Workbench_name.t -> string
val ssh_agent_file : t -> Workbench_name.t -> string
(** Where the running workbench's host agent is recorded, so a later [stop] can
    find and stop it. *)

val credentials_dir : t -> Workbench_name.t -> string
val staging_dir : t -> Workbench_name.t -> transaction_id:string -> string

val ensure_dir : string -> (unit, Ade_error.t) result
(** Create a directory and its parents if absent. *)
