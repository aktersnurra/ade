type outcome = { performed : string list; manifest_digest : string option }

type restore_mode =
  | Replace_workspace
  | Into_new_machine of Workbench_name.t

let ( let* ) = Result.bind

(* Mount points for the bounded maintenance phases. Neither targets /workspace:
   mounting over it would hide the storage-backed workspace being exported. *)
let export_mount = "/mnt/ade-export"
let import_mount = "/mnt/ade-import"
let export_helper = "/usr/local/libexec/ade/export-workspace"
let restore_helper = "/usr/local/libexec/ade/restore-workspace"
let archive_name = "workspace.tar"

(* Refusals are policy decisions the user can act on, so they are reported as
   such rather than as unreadable runtime output. *)
let failed operation reason = Ade_error.Operation_refused { operation; reason }

let transaction_id () =
  Printf.sprintf "t-%.0f-%d" (Unix.gettimeofday ()) (Unix.getpid ())

let ensure_stopped smolvm name =
  let* state = Smolvm.state smolvm name in
  match state with
  | Smolvm.Running -> Smolvm.stop smolvm name
  | _ -> Ok ()

let ensure_started smolvm name =
  let* state = Smolvm.state smolvm name in
  match state with
  | Smolvm.Running -> Ok ()
  | Smolvm.Absent -> Error (failed "maintenance" "the machine does not exist")
  | _ -> Smolvm.start smolvm name

(* Export /workspace into a host staging directory.

   The machine is started for a bounded maintenance window with no injected
   secrets, no Docker or Herdr startup, and no populated SSH agent: the guest
   is untrusted, and this window exists only to read the workspace out. *)
let export_workspace smolvm name ~staging =
  let* () = State_paths.ensure_dir staging in
  let* () = ensure_stopped smolvm name in
  let* () =
    Smolvm.attach_volume smolvm name ~host:staging ~guest:export_mount ~read_only:false
  in
  let* () = ensure_started smolvm name in
  let* _ = Smolvm.exec smolvm name [ export_helper; export_mount ] in
  let* () = ensure_stopped smolvm name in
  let* () = Smolvm.detach_volume smolvm name ~guest:export_mount in
  Ok (Filename.concat staging archive_name)

(* Validate the untrusted export on the host. The manifest proves integrity
   only: that the bytes validated are the bytes restored. It cannot prove
   completeness against a guest that was already compromised, since that guest
   already controlled the source workspace. *)
let validate_export staging =
  let* manifest = Workspace_bundle.manifest_of_directory staging in
  if manifest.Workspace_bundle.entry_count = 0 then
    Error (failed "workspace export" "the export is empty")
  else Ok (Workspace_bundle.manifest_digest manifest)

let restore_workspace smolvm name ~staging =
  let* () = ensure_stopped smolvm name in
  let* () =
    Smolvm.attach_volume smolvm name ~host:staging ~guest:import_mount ~read_only:true
  in
  let* () = ensure_started smolvm name in
  let* _ = Smolvm.exec smolvm name [ restore_helper; import_mount ] in
  let* () = ensure_stopped smolvm name in
  Smolvm.detach_volume smolvm name ~guest:import_mount

let backup ~smolvm ~paths ~declaration ~destination =
  ignore paths;
  let name = Declaration.name declaration in
  let* original = Smolvm.state smolvm name in
  let* _archive = export_workspace smolvm name ~staging:destination in
  let* digest = validate_export destination in
  (* Restore whatever state the source was in; a previously running workbench
     goes back through the normal startup checks. *)
  let* () =
    match original with
    | Smolvm.Running -> Result.map ignore (ensure_started smolvm name)
    | _ -> Ok ()
  in
  Ok { performed = [ "export"; "validate"; "restore-state" ]; manifest_digest = Some digest }

let restore ~smolvm ~paths ~declaration ~archive ~mode =
  ignore paths;
  let staging = Filename.dirname archive in
  let* digest = validate_export staging in
  let* target =
    match mode with
    | Replace_workspace -> Ok (Declaration.name declaration)
    | Into_new_machine target ->
        let* state = Smolvm.state smolvm target in
        if state <> Smolvm.Absent then
          Error (failed "restore" "the target machine already exists")
        else
          let* () = Smolvm.create smolvm declaration in
          Ok target
  in
  let* () = restore_workspace smolvm target ~staging in
  Ok { performed = [ "validate"; "restore" ]; manifest_digest = Some digest }

let reimage ~smolvm ~paths ~declaration ~force_quiesce =
  let name = Declaration.name declaration in
  let journal_path = State_paths.journal_file paths name in
  let* existing = Reimage.read ~path:journal_path in
  match Reimage.recovery_for existing with
  | Reimage.Recovery_required reason -> Error (failed "reimage" reason)
  | Reimage.Resume_from phase ->
      Error
        (failed "reimage"
           ("an unfinished transaction is at phase " ^ Reimage.phase_to_string phase))
  | Reimage.Nothing_to_recover ->
      let* state = Smolvm.state smolvm name in
      (* Refuse a running workbench unless the user accepted losing in-flight
         agent work. *)
      if state = Smolvm.Running && not force_quiesce then
        Error
          (failed "reimage"
             "the workbench is running; quiesce it or pass an explicit force")
      else
        let id = transaction_id () in
        let staging = State_paths.staging_dir paths name ~transaction_id:id in
        let digest = Declaration.digest_hex declaration in
        let base phase =
          {
            Reimage.transaction_id = id;
            machine_name = Workbench_name.to_string name;
            phase;
            old_image_digest = Declaration.image declaration;
            new_image_digest = Declaration.image declaration;
            old_declaration_digest = digest;
            new_declaration_digest = digest;
            staging_path = staging;
            workspace_manifest_digest = None;
            started_at = Unix.gettimeofday ();
          }
        in
        let write journal = Reimage.write ~path:journal_path journal in
        let* () = write (base Reimage.Quiescing) in
        let* () = write (base Reimage.Exporting) in
        let* _archive = export_workspace smolvm name ~staging in
        let* manifest = validate_export staging in
        (* The verified manifest is recorded before anything irreversible: past
           this point the export is the only remaining copy of the workspace,
           and recovery depends on knowing it was validated. *)
        let verified =
          { (base Reimage.Export_verified) with
            Reimage.workspace_manifest_digest = Some manifest }
        in
        let* () = write verified in
        let* () = Smolvm.delete smolvm name in
        let* () =
          write { verified with Reimage.phase = Reimage.Old_machine_deleted }
        in
        let* () = Smolvm.create smolvm declaration in
        let* () =
          write { verified with Reimage.phase = Reimage.New_machine_created }
        in
        let* () = write { verified with Reimage.phase = Reimage.Restoring } in
        let* () = restore_workspace smolvm name ~staging in
        let* () = write { verified with Reimage.phase = Reimage.Qualifying } in
        let* () = ensure_stopped smolvm name in
        let* () = write { verified with Reimage.phase = Reimage.Committed } in
        (* The journal is not a second lifecycle database; it is removed once
           the transaction commits. *)
        let* () = Reimage.remove ~path:journal_path in
        Ok
          {
            performed =
              [ "quiesce"; "export"; "verify"; "delete"; "create"; "restore"; "commit" ];
            manifest_digest = Some manifest;
          }

let pack ~smolvm ~declaration ~output =
  let name = Declaration.name declaration in
  let* state = Smolvm.state smolvm name in
  if state = Smolvm.Running then
    Error
      (failed "pack"
         "packing requires a stopped workbench; stop it first")
  else
    let* () = Smolvm.pack smolvm name ~output in
    Ok { performed = [ "pack" ]; manifest_digest = None }

let destroy ~smolvm ~paths ~declaration ~request ~backup_destination =
  let name = Declaration.name declaration in
  let journal_path = State_paths.journal_file paths name in
  let* journal = Reimage.read ~path:journal_path in
  match Destroy.authorize_with_journal ~journal request with
  | Error refusal -> Error (failed "destroy" (Destroy.describe_refusal refusal))
  | Ok choice ->
      let* backed_up =
        match (choice, backup_destination) with
        | Destroy.Backup_first, Some destination ->
            let* result = backup ~smolvm ~paths ~declaration ~destination in
            Ok result.manifest_digest
        | Destroy.Backup_first, None ->
            Error (failed "destroy" "a backup was requested but no destination was given")
        | Destroy.No_backup, _ -> Ok None
      in
      let* () = ensure_stopped smolvm name in
      let* () = Smolvm.delete smolvm name in
      Ok
        {
          performed =
            (match choice with
             | Destroy.Backup_first -> [ "backup"; "stop"; "delete" ]
             | Destroy.No_backup -> [ "stop"; "delete" ]);
          manifest_digest = backed_up;
        }
