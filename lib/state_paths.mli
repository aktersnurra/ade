(** Where ADE keeps its own host state.

    ADE stores only what it needs: per-workbench locks, the recorded host
    agent and secret-free credential metadata. It keeps no parallel
    database of SmolVM machines. *)

type t

val make : ?root:string -> unit -> t
(** [root] defaults to [$ADE_STATE_ROOT], then
    [$XDG_STATE_HOME/ade], then [~/.local/state/ade]. Tests always pass an
    explicit root so no test touches real user state. *)

val root : t -> string
val lock_file : t -> Workbench_name.t -> string
val outbox_dir : t -> Workbench_name.t -> string
(** Where a clone workbench's guest drops git bundles. Everything in it is
    written by the guest and so untrusted until validated. *)

val ssh_agent_file : t -> Workbench_name.t -> string
(** Where the running workbench's host agent is recorded, so a later [stop] can
    find and stop it. *)

val created_file : t -> Workbench_name.t -> string
(** What the machine was created with, for drift reports. *)

val credentials_dir : t -> Workbench_name.t -> string
val workbench_dir : t -> Workbench_name.t -> string
(** Everything ADE keeps for one workbench; removed with the workbench. *)

val ensure_dir : string -> (unit, Ade_error.t) result
(** Create a directory and its parents if absent. *)

val net_dir : t -> Workbench_name.t -> string
val net_log : t -> Workbench_name.t -> string
(** The egress proxy's decisions and classifications, one JSON object a line. *)

val session_allow_file : t -> Workbench_name.t -> string
(** Hosts allowed with [ade net allow] until the workbench next starts. *)

val proxy_pid_file : t -> Workbench_name.t -> string
(** Held locked by the running proxy, so a stale pid is never signalled. *)

val proxy_output_file : t -> Workbench_name.t -> string
