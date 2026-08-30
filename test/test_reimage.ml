open Ade

let all_phases =
  [
    Reimage.Quiescing;
    Reimage.Exporting;
    Reimage.Export_verified;
    Reimage.Old_machine_deleted;
    Reimage.New_machine_created;
    Reimage.Restoring;
    Reimage.Qualifying;
    Reimage.Committed;
    Reimage.Rollback_required;
  ]

let journal ?(phase = Reimage.Quiescing) ?(manifest = Some "abc123") () =
  {
    Reimage.transaction_id = "t-0001";
    machine_name = "work";
    phase;
    old_image_digest = "sha256:" ^ String.make 64 'a';
    new_image_digest = "sha256:" ^ String.make 64 'b';
    old_declaration_digest = String.make 64 'c';
    new_declaration_digest = String.make 64 'd';
    staging_path = "/tmp/ade/staging/t-0001";
    workspace_manifest_digest = manifest;
    started_at = 1756500000.0;
  }

let phase_names_round_trip () =
  List.iter
    (fun phase ->
      let rendered = Reimage.phase_to_string phase in
      match Reimage.phase_of_string rendered with
      | Ok parsed ->
          Alcotest.(check string) rendered rendered (Reimage.phase_to_string parsed)
      | Error reason -> Alcotest.failf "%s: %s" rendered reason)
    all_phases

let unknown_phase_is_rejected () =
  match Reimage.phase_of_string "teleporting" with
  | Ok _ -> Alcotest.fail "expected an unknown phase to be rejected"
  | Error _ -> ()

let journals_round_trip_through_json () =
  List.iter
    (fun phase ->
      let original = journal ~phase () in
      match Reimage.of_json (Reimage.to_json original) with
      | Error error -> Alcotest.failf "of_json: %s" (Ade_error.to_string error)
      | Ok parsed ->
          Alcotest.(check string) "id" original.Reimage.transaction_id
            parsed.Reimage.transaction_id;
          Alcotest.(check string) "phase"
            (Reimage.phase_to_string original.Reimage.phase)
            (Reimage.phase_to_string parsed.Reimage.phase);
          Alcotest.(check (option string)) "manifest"
            original.Reimage.workspace_manifest_digest
            parsed.Reimage.workspace_manifest_digest)
    all_phases

let malformed_json_is_rejected () =
  match Reimage.of_json "{not json" with
  | Ok _ -> Alcotest.fail "expected malformed JSON to be rejected"
  | Error _ -> ()

let missing_field_is_rejected () =
  match Reimage.of_json {|{"transaction_id":"t-1"}|} with
  | Ok _ -> Alcotest.fail "expected a truncated journal to be rejected"
  | Error _ -> ()

let temp_path () =
  let path = Filename.temp_file "ade-journal-" ".json" in
  Sys.remove path;
  path

let writing_then_reading_preserves_the_journal () =
  let path = temp_path () in
  let original = journal ~phase:Reimage.Export_verified () in
  (match Reimage.write ~path original with
   | Ok () -> ()
   | Error error -> Alcotest.failf "write: %s" (Ade_error.to_string error));
  match Reimage.read ~path with
  | Error error -> Alcotest.failf "read: %s" (Ade_error.to_string error)
  | Ok None -> Alcotest.fail "expected a journal"
  | Ok (Some parsed) ->
      Alcotest.(check string) "phase" "export_verified"
        (Reimage.phase_to_string parsed.Reimage.phase)

let absent_journal_reads_as_none () =
  match Reimage.read ~path:(temp_path ()) with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "expected no journal"
  | Error error -> Alcotest.failf "read: %s" (Ade_error.to_string error)

(* A journal is rewritten at every phase transition, so writing over an existing
   one must leave a whole journal behind, never a mixture of two. *)
let rewriting_a_journal_is_atomic () =
  let path = temp_path () in
  List.iter
    (fun phase ->
      match Reimage.write ~path (journal ~phase ()) with
      | Ok () -> (
          match Reimage.read ~path with
          | Ok (Some parsed) ->
              Alcotest.(check string) "phase" (Reimage.phase_to_string phase)
                (Reimage.phase_to_string parsed.Reimage.phase)
          | Ok None -> Alcotest.fail "journal vanished"
          | Error error -> Alcotest.failf "read: %s" (Ade_error.to_string error))
      | Error error -> Alcotest.failf "write: %s" (Ade_error.to_string error))
    all_phases

let no_journal_means_nothing_to_recover () =
  match Reimage.recovery_for None with
  | Reimage.Nothing_to_recover -> ()
  | _ -> Alcotest.fail "expected nothing to recover"

let a_committed_journal_needs_no_recovery () =
  match Reimage.recovery_for (Some (journal ~phase:Reimage.Committed ())) with
  | Reimage.Nothing_to_recover -> ()
  | _ -> Alcotest.fail "expected a committed transaction to need no recovery"

(* Before the export is verified, nothing irreversible has happened: the old
   machine is intact, so the transaction can simply be resumed. *)
let phases_before_deletion_resume () =
  List.iter
    (fun phase ->
      match Reimage.recovery_for (Some (journal ~phase ())) with
      | Reimage.Resume_from resumed ->
          Alcotest.(check string) "resume phase" (Reimage.phase_to_string phase)
            (Reimage.phase_to_string resumed)
      | Reimage.Nothing_to_recover -> Alcotest.failf "%s: expected resume" (Reimage.phase_to_string phase)
      | Reimage.Recovery_required reason ->
          Alcotest.failf "%s: unexpected manual recovery: %s"
            (Reimage.phase_to_string phase) reason)
    [ Reimage.Quiescing; Reimage.Exporting; Reimage.Export_verified ]

(* After the old machine is deleted, the export is the only copy of the
   workspace, so a journal without a verified manifest must never be resumed
   automatically. *)
let deletion_without_a_manifest_requires_recovery () =
  List.iter
    (fun phase ->
      match Reimage.recovery_for (Some (journal ~phase ~manifest:None ())) with
      | Reimage.Recovery_required _ -> ()
      | _ ->
          Alcotest.failf "%s: expected explicit recovery" (Reimage.phase_to_string phase))
    [ Reimage.Old_machine_deleted; Reimage.New_machine_created; Reimage.Restoring ]

let rollback_required_is_never_automatic () =
  match Reimage.recovery_for (Some (journal ~phase:Reimage.Rollback_required ())) with
  | Reimage.Recovery_required _ -> ()
  | _ -> Alcotest.fail "expected explicit recovery"

(* Every phase must be classifiable; a phase ADE cannot reason about would mean
   guessing about a half-deleted machine. *)
let every_phase_has_a_recovery_decision () =
  List.iter
    (fun phase ->
      match Reimage.recovery_for (Some (journal ~phase ())) with
      | Reimage.Nothing_to_recover | Reimage.Resume_from _ | Reimage.Recovery_required _ -> ())
    all_phases

let destructive_actions_accumulate () =
  Alcotest.(check (list string)) "quiescing" [] (Reimage.destructive_actions_before Reimage.Quiescing);
  let after_deletion = Reimage.destructive_actions_before Reimage.Old_machine_deleted in
  Alcotest.(check bool) "deletion recorded" true (List.length after_deletion > 0)

let () =
  Alcotest.run "reimage"
    [ ( "phases",
        [ Alcotest.test_case "round trip" `Quick phase_names_round_trip;
          Alcotest.test_case "unknown" `Quick unknown_phase_is_rejected ] );
      ( "journal",
        [ Alcotest.test_case "json round trip" `Quick journals_round_trip_through_json;
          Alcotest.test_case "malformed" `Quick malformed_json_is_rejected;
          Alcotest.test_case "truncated" `Quick missing_field_is_rejected;
          Alcotest.test_case "write and read" `Quick writing_then_reading_preserves_the_journal;
          Alcotest.test_case "absent" `Quick absent_journal_reads_as_none;
          Alcotest.test_case "atomic rewrite" `Quick rewriting_a_journal_is_atomic ] );
      ( "recovery",
        [ Alcotest.test_case "none" `Quick no_journal_means_nothing_to_recover;
          Alcotest.test_case "committed" `Quick a_committed_journal_needs_no_recovery;
          Alcotest.test_case "resume" `Quick phases_before_deletion_resume;
          Alcotest.test_case "after deletion" `Quick deletion_without_a_manifest_requires_recovery;
          Alcotest.test_case "rollback" `Quick rollback_required_is_never_automatic;
          Alcotest.test_case "total" `Quick every_phase_has_a_recovery_decision;
          Alcotest.test_case "destructive" `Quick destructive_actions_accumulate ] )
    ]
