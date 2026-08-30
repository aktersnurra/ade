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

let phase_to_string = function
  | Quiescing -> "quiescing"
  | Exporting -> "exporting"
  | Export_verified -> "export_verified"
  | Old_machine_deleted -> "old_machine_deleted"
  | New_machine_created -> "new_machine_created"
  | Restoring -> "restoring"
  | Qualifying -> "qualifying"
  | Committed -> "committed"
  | Rollback_required -> "rollback_required"

let phase_of_string = function
  | "quiescing" -> Ok Quiescing
  | "exporting" -> Ok Exporting
  | "export_verified" -> Ok Export_verified
  | "old_machine_deleted" -> Ok Old_machine_deleted
  | "new_machine_created" -> Ok New_machine_created
  | "restoring" -> Ok Restoring
  | "qualifying" -> Ok Qualifying
  | "committed" -> Ok Committed
  | "rollback_required" -> Ok Rollback_required
  | other -> Error ("unrecognized transaction phase " ^ Filename.quote other)

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

let to_json journal =
  `Assoc
    [
      ("transaction_id", `String journal.transaction_id);
      ("machine_name", `String journal.machine_name);
      ("phase", `String (phase_to_string journal.phase));
      ("old_image_digest", `String journal.old_image_digest);
      ("new_image_digest", `String journal.new_image_digest);
      ("old_declaration_digest", `String journal.old_declaration_digest);
      ("new_declaration_digest", `String journal.new_declaration_digest);
      ("staging_path", `String journal.staging_path);
      ( "workspace_manifest_digest",
        match journal.workspace_manifest_digest with
        | Some digest -> `String digest
        | None -> `Null );
      ("started_at", `Float journal.started_at);
    ]
  |> Yojson.Safe.to_string

let invalid reason = Ade_error.Runtime_output_invalid { context = "reimage journal"; reason }

let of_json text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error reason -> Error (invalid reason)
  | json -> (
      let string_field name =
        match Yojson.Safe.Util.member name json with
        | `String value -> Ok value
        | `Null -> Error (invalid ("missing field " ^ name))
        | _ -> Error (invalid ("field " ^ name ^ " must be a string"))
      in
      let ( let* ) = Result.bind in
      let* transaction_id = string_field "transaction_id" in
      let* machine_name = string_field "machine_name" in
      let* phase_name = string_field "phase" in
      let* phase = Result.map_error invalid (phase_of_string phase_name) in
      let* old_image_digest = string_field "old_image_digest" in
      let* new_image_digest = string_field "new_image_digest" in
      let* old_declaration_digest = string_field "old_declaration_digest" in
      let* new_declaration_digest = string_field "new_declaration_digest" in
      let* staging_path = string_field "staging_path" in
      let workspace_manifest_digest =
        match Yojson.Safe.Util.member "workspace_manifest_digest" json with
        | `String digest -> Some digest
        | _ -> None
      in
      let* started_at =
        match Yojson.Safe.Util.member "started_at" json with
        | `Float value -> Ok value
        | `Int value -> Ok (float_of_int value)
        | _ -> Error (invalid "missing field started_at")
      in
      Ok
        {
          transaction_id;
          machine_name;
          phase;
          old_image_digest;
          new_image_digest;
          old_declaration_digest;
          new_declaration_digest;
          staging_path;
          workspace_manifest_digest;
          started_at;
        })

(* Written temp-then-rename, with an fsync of both the file and its directory.
   Every phase transition is persisted before the next destructive action, so a
   crash must never leave a half-written journal that would misreport how far
   the transaction got. *)
let write ~path journal =
  let directory = Filename.dirname path in
  match State_paths.ensure_dir directory with
  | Error _ as error -> error
  | Ok () -> (
      let temporary = path ^ ".tmp" in
      try
        let fd =
          Unix.openfile temporary [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
        in
        let payload = to_json journal in
        let written = Unix.write_substring fd payload 0 (String.length payload) in
        if written <> String.length payload then (
          Unix.close fd;
          Error (invalid "short write"))
        else (
          Unix.fsync fd;
          Unix.close fd;
          Unix.rename temporary path;
          (* Renaming is only durable once the directory entry is flushed. *)
          let dir_fd = Unix.openfile directory [ Unix.O_RDONLY ] 0o700 in
          (try Unix.fsync dir_fd with Unix.Unix_error _ -> ());
          Unix.close dir_fd;
          Ok ())
      with Unix.Unix_error (error, _, _) -> Error (invalid (Unix.error_message error)))

let read ~path =
  if not (Sys.file_exists path) then Ok None
  else
    try
      let channel = open_in_bin path in
      let length = in_channel_length channel in
      let contents = really_input_string channel length in
      close_in channel;
      Result.map Option.some (of_json contents)
    with Sys_error reason -> Error (invalid reason)

let remove ~path =
  if not (Sys.file_exists path) then Ok ()
  else try Sys.remove path; Ok () with Sys_error reason -> Error (invalid reason)

type recovery =
  | Nothing_to_recover
  | Resume_from of phase
  | Recovery_required of string

let destructive_actions_before = function
  | Quiescing | Exporting | Export_verified -> []
  | Old_machine_deleted -> [ "deleted the old machine and its workspace storage" ]
  | New_machine_created | Restoring | Qualifying ->
      [ "deleted the old machine and its workspace storage"; "created the new machine" ]
  | Committed -> [ "completed the reimage" ]
  | Rollback_required -> [ "left the transaction in an unrecoverable state" ]

let recovery_for = function
  | None -> Nothing_to_recover
  | Some journal -> (
      match journal.phase with
      | Committed -> Nothing_to_recover
      | Rollback_required ->
          Recovery_required "the transaction was marked as requiring explicit rollback"
      (* Nothing irreversible has happened yet: the old machine is intact, so
         the transaction can be restarted from where it stopped. *)
      | Quiescing | Exporting | Export_verified -> Resume_from journal.phase
      (* Past this point the old machine, and with it the only other copy of the
         workspace, is gone. Resuming is safe only while ADE still holds a
         verified export to restore from. *)
      | Old_machine_deleted | New_machine_created | Restoring | Qualifying -> (
          match journal.workspace_manifest_digest with
          | Some _ -> Resume_from journal.phase
          | None ->
              Recovery_required
                ("the old machine was already deleted but no verified workspace export \
                  is recorded (phase " ^ phase_to_string journal.phase ^ ")")))
