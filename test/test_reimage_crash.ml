open Ade

(* Crash injection at every journal boundary.

   Reimage is the one operation where a defect costs a workspace, so each test
   kills the transaction at a specific step and asserts what a later command
   would do with the journal left behind. The rule under test is that recovery
   is decided by what the phase has already destroyed, never by optimism. *)

type fake = {
  mutable state : string;
  mutable calls : string list;
  (* Fail the nth call to this verb, simulating a crash mid-transaction. *)
  fail_verb : string option;
  fail_after : int;
  mutable seen : int;
}

let verb request =
  match request.Process_runner.argv with
  | "machine" :: v :: _ -> v
  | "pack" :: v :: _ -> "pack-" ^ v
  | _ -> "?"

let write_fake_archive request =
  let rec staging_of = function
    | "--volume" :: spec :: _ -> (
        match String.split_on_char ':' spec with host :: _ -> Some host | [] -> None)
    | _ :: rest -> staging_of rest
    | [] -> None
  in
  match staging_of request.Process_runner.argv with
  | None -> ()
  | Some host ->
      (try if not (Sys.file_exists host) then Unix.mkdir host 0o700
       with Unix.Unix_error _ -> ());
      let path = Filename.concat host "workspace.tar" in
      (try
         let channel = open_out_bin path in
         output_string channel "fake workspace archive";
         close_out channel
       with Sys_error _ -> ())

let runner fake request =
  let v = verb request in
  fake.calls <- fake.calls @ [ v ];
  let crash_here =
    match fake.fail_verb with
    | Some target when target = v ->
        fake.seen <- fake.seen + 1;
        fake.seen > fake.fail_after
    | _ -> false
  in
  if crash_here then
    Ok { Process_runner.status = 1; stdout = ""; stderr = "simulated crash" }
  else begin
    if v = "update" then write_fake_archive request;
    match v with
    | "status" ->
        if fake.state = "absent" then
          Ok { Process_runner.status = 1; stdout = ""; stderr = "machine 'work' not found" }
        else
          Ok
            {
              Process_runner.status = 0;
              stdout = Printf.sprintf {|{"name":"work","state":"%s"}|} fake.state;
              stderr = "";
            }
    | "create" -> fake.state <- "created"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
    | "start" -> fake.state <- "running"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
    | "stop" -> fake.state <- "stopped"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
    | "delete" -> fake.state <- "absent"; Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
    | _ -> Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  end

let temp_root () =
  let p = Filename.temp_file "ade-crash-" "" in
  Sys.remove p;
  p

let setup ?fail_verb ?(fail_after = 0) initial =
  let fake =
    { state = initial; calls = []; fail_verb; fail_after; seen = 0 }
  in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake) in
  (fake, smolvm, State_paths.make ~root:(temp_root ()) ())

let declaration () =
  match Declaration.load "../workbenches/work.toml" with
  | Ok d -> d
  | Error e -> Alcotest.failf "declaration: %s" (Ade_error.to_string e)

let journal_after paths =
  let name = Declaration.name (declaration ()) in
  match Reimage.read ~path:(State_paths.journal_file paths name) with
  | Ok journal -> journal
  | Error e -> Alcotest.failf "journal read: %s" (Ade_error.to_string e)

let render_recovery = function
  | Reimage.Nothing_to_recover -> "nothing"
  | Reimage.Resume_from _ -> "resume"
  | Reimage.Recovery_required _ -> "manual"

(* Crashing during the export leaves the old machine intact, so the safe
   action is to resume: nothing irreversible has happened. *)
let a_crash_during_export_leaves_the_machine_intact () =
  let fake, smolvm, paths = setup ~fail_verb:"exec" "stopped" in
  let _ = Maintenance.reimage ~smolvm ~paths ~declaration:(declaration ()) ~force_quiesce:true in
  Alcotest.(check bool) "machine not deleted" false (List.mem "delete" fake.calls);
  Alcotest.(check string) "resumable" "resume"
    (render_recovery (Reimage.recovery_for (journal_after paths)))

(* A journal recording deletion without a verified manifest must never resume
   automatically: the export is the only remaining copy of the workspace and
   ADE cannot show it was validated. *)
let deletion_without_a_verified_manifest_requires_manual_recovery () =
  let journal =
    Some
      {
        Reimage.transaction_id = "t-crash";
        machine_name = "work";
        phase = Reimage.Old_machine_deleted;
        old_image_digest = "";
        new_image_digest = "";
        old_declaration_digest = "";
        new_declaration_digest = "";
        staging_path = "/tmp/staging";
        workspace_manifest_digest = None;
        started_at = 0.0;
      }
  in
  Alcotest.(check string) "manual" "manual" (render_recovery (Reimage.recovery_for journal))

(* With a verified manifest recorded, the same phase is resumable: the export
   is known good, so recreate and restore can proceed. *)
let deletion_with_a_verified_manifest_resumes () =
  let journal =
    Some
      {
        Reimage.transaction_id = "t-crash";
        machine_name = "work";
        phase = Reimage.Old_machine_deleted;
        old_image_digest = "";
        new_image_digest = "";
        old_declaration_digest = "";
        new_declaration_digest = "";
        staging_path = "/tmp/staging";
        workspace_manifest_digest = Some "abc123";
        started_at = 0.0;
      }
  in
  Alcotest.(check string) "resume" "resume" (render_recovery (Reimage.recovery_for journal))

(* Every phase must have a decision. A phase ADE could not classify would mean
   guessing about a half-deleted machine. *)
let every_phase_is_classified_both_with_and_without_a_manifest () =
  let phases =
    [
      Reimage.Quiescing; Reimage.Exporting; Reimage.Export_verified;
      Reimage.Old_machine_deleted; Reimage.New_machine_created; Reimage.Restoring;
      Reimage.Qualifying; Reimage.Committed; Reimage.Rollback_required;
    ]
  in
  List.iter
    (fun manifest ->
      List.iter
        (fun phase ->
          let journal =
            Some
              {
                Reimage.transaction_id = "t";
                machine_name = "work";
                phase;
                old_image_digest = "";
                new_image_digest = "";
                old_declaration_digest = "";
                new_declaration_digest = "";
                staging_path = "/tmp/s";
                workspace_manifest_digest = manifest;
                started_at = 0.0;
              }
          in
          match Reimage.recovery_for journal with
          | Reimage.Nothing_to_recover | Reimage.Resume_from _
          | Reimage.Recovery_required _ -> ())
        phases)
    [ None; Some "digest" ]

(* Phases past deletion must name what they destroyed, so a recovery message
   can say why manual intervention is needed. *)
let destructive_phases_report_what_they_destroyed () =
  List.iter
    (fun phase ->
      let actions = Reimage.destructive_actions_before phase in
      Alcotest.(check bool)
        (Reimage.phase_to_string phase ^ " names its damage")
        true
        (List.exists (fun a -> a <> "") actions))
    [ Reimage.Old_machine_deleted; Reimage.New_machine_created; Reimage.Restoring ]

let pre_deletion_phases_report_no_damage () =
  List.iter
    (fun phase ->
      Alcotest.(check (list string))
        (Reimage.phase_to_string phase ^ " destroyed nothing")
        [] (Reimage.destructive_actions_before phase))
    [ Reimage.Quiescing; Reimage.Exporting; Reimage.Export_verified ]

(* A second reimage must refuse while a transaction is unfinished, rather than
   starting a fresh one over a half-migrated machine. *)
let an_unfinished_transaction_blocks_a_new_reimage () =
  let _, smolvm, paths = setup ~fail_verb:"exec" "stopped" in
  let d = declaration () in
  let _ = Maintenance.reimage ~smolvm ~paths ~declaration:d ~force_quiesce:true in
  match Maintenance.reimage ~smolvm ~paths ~declaration:d ~force_quiesce:true with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an unfinished transaction to block a new reimage"

(* The journal must survive a crash: recovery depends on reading it back. *)
let the_journal_survives_a_crash () =
  let _, smolvm, paths = setup ~fail_verb:"exec" "stopped" in
  let _ = Maintenance.reimage ~smolvm ~paths ~declaration:(declaration ()) ~force_quiesce:true in
  match journal_after paths with
  | None -> Alcotest.fail "the journal was lost, so recovery is impossible"
  | Some journal ->
      Alcotest.(check string) "names the machine" "work" journal.Reimage.machine_name

let () =
  Alcotest.run "reimage_crash"
    [ ( "during export",
        [ Alcotest.test_case "machine intact" `Quick
            a_crash_during_export_leaves_the_machine_intact;
          Alcotest.test_case "journal survives" `Quick the_journal_survives_a_crash;
          Alcotest.test_case "blocks retry" `Quick
            an_unfinished_transaction_blocks_a_new_reimage ] );
      ( "after deletion",
        [ Alcotest.test_case "no manifest" `Quick
            deletion_without_a_verified_manifest_requires_manual_recovery;
          Alcotest.test_case "with manifest" `Quick
            deletion_with_a_verified_manifest_resumes ] );
      ( "classification",
        [ Alcotest.test_case "total" `Quick
            every_phase_is_classified_both_with_and_without_a_manifest;
          Alcotest.test_case "destructive named" `Quick
            destructive_phases_report_what_they_destroyed;
          Alcotest.test_case "pre-deletion clean" `Quick
            pre_deletion_phases_report_no_damage ] )
    ]
