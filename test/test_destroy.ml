open Ade

let name_exn value =
  match Workbench_name.of_string value with
  | Ok name -> name
  | Error _ -> Alcotest.failf "bad name %s" value

let request ?(choice = Destroy.No_backup) ?confirmation name =
  { Destroy.name = name_exn name; choice; confirmation }

(* Destroy is irreversible, so it must never proceed on a bare command. *)
let confirmation_is_required () =
  match Destroy.authorize (request "work") with
  | Error Destroy.Missing_confirmation -> ()
  | Error other -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal other)
  | Ok _ -> Alcotest.fail "expected a refusal without confirmation"

let confirmation_must_match_the_workbench () =
  match Destroy.authorize (request ~confirmation:"personal" "work") with
  | Error (Destroy.Confirmation_mismatch _) -> ()
  | Error other -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal other)
  | Ok _ -> Alcotest.fail "expected a mismatched confirmation to be refused"

let a_matching_confirmation_authorizes () =
  match Destroy.authorize (request ~confirmation:"work" "work") with
  | Ok Destroy.No_backup -> ()
  | Ok _ -> Alcotest.fail "unexpected choice"
  | Error refusal -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal refusal)

let the_backup_choice_is_preserved () =
  match
    Destroy.authorize (request ~choice:Destroy.Backup_first ~confirmation:"work" "work")
  with
  | Ok Destroy.Backup_first -> ()
  | Ok _ -> Alcotest.fail "expected the backup choice to be preserved"
  | Error refusal -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal refusal)

let journal phase manifest =
  Some
    {
      Reimage.transaction_id = "t-1";
      machine_name = "work";
      phase;
      old_image_digest = "";
      new_image_digest = "";
      old_declaration_digest = "";
      new_declaration_digest = "";
      staging_path = "";
      workspace_manifest_digest = manifest;
      started_at = 0.0;
    }

(* Destroying during an unfinished transaction could delete the machine the
   recovery path still needs. *)
let an_unfinished_transaction_blocks_destroy () =
  match
    Destroy.authorize_with_journal
      ~journal:(journal Reimage.Exporting (Some "abc"))
      (request ~confirmation:"work" "work")
  with
  | Error (Destroy.Unfinished_transaction _) -> ()
  | Error other -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal other)
  | Ok _ -> Alcotest.fail "expected an unfinished transaction to block destroy"

let a_committed_transaction_does_not_block_destroy () =
  match
    Destroy.authorize_with_journal
      ~journal:(journal Reimage.Committed None)
      (request ~confirmation:"work" "work")
  with
  | Ok _ -> ()
  | Error refusal -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal refusal)

let no_journal_does_not_block_destroy () =
  match
    Destroy.authorize_with_journal ~journal:None (request ~confirmation:"work" "work")
  with
  | Ok _ -> ()
  | Error refusal -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal refusal)

(* Even with no journal, confirmation is still required. *)
let the_journal_check_does_not_bypass_confirmation () =
  match Destroy.authorize_with_journal ~journal:None (request "work") with
  | Error Destroy.Missing_confirmation -> ()
  | Error other -> Alcotest.failf "unexpected: %s" (Destroy.describe_refusal other)
  | Ok _ -> Alcotest.fail "expected confirmation to still be required"

let the_prompt_names_the_workbench () =
  let prompt = Destroy.confirmation_prompt (name_exn "work") in
  let contains needle =
    let hl = String.length prompt and nl = String.length needle in
    let rec scan i = i + nl <= hl && (String.sub prompt i nl = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "names the workbench" true (contains "destroy work");
  Alcotest.(check bool) "offers backup" true (contains "backup");
  Alcotest.(check bool) "offers abort" true (contains "Abort")

let () =
  Alcotest.run "destroy"
    [ ( "authorization",
        [ Alcotest.test_case "confirmation required" `Quick confirmation_is_required;
          Alcotest.test_case "must match" `Quick confirmation_must_match_the_workbench;
          Alcotest.test_case "authorizes" `Quick a_matching_confirmation_authorizes;
          Alcotest.test_case "choice preserved" `Quick the_backup_choice_is_preserved ] );
      ( "transactions",
        [ Alcotest.test_case "unfinished blocks" `Quick an_unfinished_transaction_blocks_destroy;
          Alcotest.test_case "committed allows" `Quick a_committed_transaction_does_not_block_destroy;
          Alcotest.test_case "no journal" `Quick no_journal_does_not_block_destroy;
          Alcotest.test_case "still confirms" `Quick the_journal_check_does_not_bypass_confirmation ] );
      ( "prompt", [ Alcotest.test_case "names workbench" `Quick the_prompt_names_the_workbench ] )
    ]
