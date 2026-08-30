(** Destroy, and the explicit choices it requires.

    Destroy removes the machine and all machine-owned state: root, workspace,
    Docker, Herdr, caches, login state and tmpfs secrets. It leaves host
    declarations and separately retained backups alone.

    ADE never infers safety from a recent backup, because it cannot know whether
    the workspace changed afterward. Deletion is logical deletion, not
    guaranteed physical erasure from APFS, SSDs, snapshots or host backups. *)

type backup_choice =
  | Backup_first
  | No_backup

type request = {
  name : Workbench_name.t;
  choice : backup_choice;
  confirmation : string option;
      (** Must equal the workbench name. Noninteractive callers pass
          [--confirm-destroy-workspace=NAME]. *)
}

type refusal =
  | Missing_choice
  | Missing_confirmation
  | Confirmation_mismatch of { expected : string; given : string }
  | Unfinished_transaction of string

val describe_refusal : refusal -> string

val authorize : request -> (backup_choice, refusal) result
(** Decide whether a destroy may proceed. Pure, so the rule is testable without
    deleting anything. *)

val authorize_with_journal :
  journal:Reimage.journal option -> request -> (backup_choice, refusal) result
(** Destroying an absent machine succeeds as a no-op only when no unfinished ADE
    transaction exists. *)

val confirmation_prompt : Workbench_name.t -> string
