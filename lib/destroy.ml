type backup_choice = Backup_first | No_backup

type request = {
  name : Workbench_name.t;
  choice : backup_choice;
  confirmation : string option;
}

type refusal =
  | Missing_choice
  | Missing_confirmation
  | Confirmation_mismatch of { expected : string; given : string }
  | Unfinished_transaction of string

let describe_refusal = function
  | Missing_choice ->
      "choose --backup-first or --no-backup before destroying a workbench"
  | Missing_confirmation ->
      "destroying a workbench requires --confirm-destroy-workspace=NAME"
  | Confirmation_mismatch { expected; given } ->
      Printf.sprintf "confirmation %s does not match workbench %s" (Filename.quote given)
        (Filename.quote expected)
  | Unfinished_transaction reason -> "an unfinished ADE transaction exists: " ^ reason

let authorize request =
  let expected = Workbench_name.to_string request.name in
  match request.confirmation with
  | None -> Error Missing_confirmation
  | Some given when given <> expected -> Error (Confirmation_mismatch { expected; given })
  | Some _ -> Ok request.choice

let authorize_with_journal ~journal request =
  (* A destroy during an unfinished transaction could delete the machine that
     the recovery path still needs, so it is refused until recovery finishes. *)
  match Reimage.recovery_for journal with
  | Reimage.Nothing_to_recover -> authorize request
  | Reimage.Resume_from phase ->
      Error (Unfinished_transaction ("transaction is at phase " ^ Reimage.phase_to_string phase))
  | Reimage.Recovery_required reason -> Error (Unfinished_transaction reason)

let confirmation_prompt name =
  let value = Workbench_name.to_string name in
  String.concat "\n"
    [
      Printf.sprintf "Destroying workbench %s removes its workspace, Docker state," value;
      "caches, login state and all other machine-owned data.";
      "";
      "1. Create a workspace backup, then destroy";
      "2. Destroy without creating a backup";
      "3. Abort";
      "";
      Printf.sprintf "Type \"destroy %s\" to continue:" value;
    ]
