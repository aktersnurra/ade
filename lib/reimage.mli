(** The crash-recoverable reimage transaction.

    Reimage is ADE-owned rather than delegated to SmolVM because deleting a
    machine destroys its machine-owned workspace storage. The invariant is that
    ADE never deletes the old machine until it holds a complete, validated
    workspace export.

    That protects against interrupted, truncated or unsafe archives. It does not
    prove completeness against a guest that was already malicious: such a guest
    already controlled the source workspace. *)

type phase =
  | Quiescing
  | Exporting
  | Export_verified
  | Old_machine_deleted
  | New_machine_created
  | Restoring
  | Qualifying
  | Committed
  | Rollback_required

val phase_to_string : phase -> string
val phase_of_string : string -> (phase, string) result

type journal = {
  transaction_id : string;
  machine_name : string;
  phase : phase;
  old_image_digest : string;
  new_image_digest : string;
  old_declaration_digest : string;
  new_declaration_digest : string;
  staging_path : string;
  workspace_manifest_digest : string option;
  started_at : float;
}

val to_json : journal -> string
val of_json : string -> (journal, Ade_error.t) result

val write : path:string -> journal -> (unit, Ade_error.t) result
(** Persist atomically: write a temporary file, fsync it, then rename. A journal
    read after a crash is therefore always a whole journal, never a partial
    one. *)

val read : path:string -> (journal option, Ade_error.t) result
val remove : path:string -> (unit, Ade_error.t) result

type recovery =
  | Nothing_to_recover
  | Resume_from of phase
  | Recovery_required of string

val recovery_for : journal option -> recovery
(** Decide what a later command must do when it finds a journal. Commands never
    start an arbitrary half-constructed machine. *)

val destructive_actions_before : phase -> string list
(** The irreversible steps a phase has already performed. Used to explain why a
    given phase can or cannot be resumed automatically. *)
