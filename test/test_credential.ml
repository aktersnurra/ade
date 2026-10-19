open Ade

let now = 1_756_500_000.0

let generation ?(number = 1) ?(provider = Credential.Github) expires_at =
  { Credential.number; provider; expires_at; installed_at = now }

let empty_credentials_are_rejected () =
  match Credential.validate ~now ~value:"" ~expires_at:(now +. 3600.0) with
  | Error Credential.Empty_value -> ()
  | Error other ->
      Alcotest.failf "unexpected: %s" (Credential.describe_validation_error other)
  | Ok () -> Alcotest.fail "expected an empty credential to be rejected"

let already_expired_credentials_are_rejected () =
  match Credential.validate ~now ~value:"token" ~expires_at:(now -. 1.0) with
  | Error Credential.Already_expired -> ()
  | Error other ->
      Alcotest.failf "unexpected: %s" (Credential.describe_validation_error other)
  | Ok () -> Alcotest.fail "expected an expired credential to be rejected"

(* A long-lived credential is not what ADE asked for and must not be installed
   as if it were short-lived. *)
let overly_long_credentials_are_rejected () =
  match Credential.validate ~now ~value:"token" ~expires_at:(now +. (48.0 *. 3600.0)) with
  | Error (Credential.Expiry_too_far _) -> ()
  | Error other ->
      Alcotest.failf "unexpected: %s" (Credential.describe_validation_error other)
  | Ok () -> Alcotest.fail "expected an overly long credential to be rejected"

let a_valid_credential_is_accepted () =
  match Credential.validate ~now ~value:"token" ~expires_at:(now +. 3600.0) with
  | Ok () -> ()
  | Error other ->
      Alcotest.failf "unexpected: %s" (Credential.describe_validation_error other)

(* Generations are immutable and numbered; activation swaps a symlink. *)
let generations_are_written_under_tmpfs () =
  let root = "/run/ade/secrets" in
  Alcotest.(check string) "generation" "/run/ade/secrets/generation-3"
    (Credential.generation_path ~root 3);
  Alcotest.(check string) "current" "/run/ade/secrets/current"
    (Credential.current_path ~root)

let generation_numbers_increase () =
  Alcotest.(check int) "first" 1 (Credential.next_number None);
  Alcotest.(check int) "next" 2 (Credential.next_number (Some (generation (now +. 60.0))));
  Alcotest.(check int) "after third" 4
    (Credential.next_number (Some (generation ~number:3 (now +. 60.0))))

(* The audit record must identify what happened without revealing the secret. *)
let audit_records_are_secret_free () =
  let line =
    Credential.audit_line
      {
        Credential.provider = Credential.Github;
        generation_number = 7;
        expires_at = now +. 3600.0;
        outcome = "installed";
      }
  in
  let contains needle =
    let hl = String.length line and nl = String.length needle in
    let rec scan i = i + nl <= hl && (String.sub line i nl = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "names provider" true (contains "github");
  Alcotest.(check bool) "names generation" true (contains "generation=7");
  Alcotest.(check bool) "records outcome" true (contains "installed");
  Alcotest.(check bool) "no secret" false (contains "token")

let () =
  Alcotest.run "credential"
    [ ( "validation",
        [ Alcotest.test_case "empty" `Quick empty_credentials_are_rejected;
          Alcotest.test_case "expired" `Quick already_expired_credentials_are_rejected;
          Alcotest.test_case "too long" `Quick overly_long_credentials_are_rejected;
          Alcotest.test_case "valid" `Quick a_valid_credential_is_accepted ] );
      ( "installation",
        [ Alcotest.test_case "tmpfs paths" `Quick generations_are_written_under_tmpfs;
          Alcotest.test_case "numbering" `Quick generation_numbers_increase;
          Alcotest.test_case "audit" `Quick audit_records_are_secret_free ] )
    ]
