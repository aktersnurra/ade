open Ade

(* Assembled at runtime so nothing in this file resembles a credential. *)
let payload = "FAKE" ^ "-credential-bytes"

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let reader_returning value _source = Ok value

(* Commit-time guarantee: a reference names a location, never a credential, so
   a secret cannot be written into a declaration in the first place. *)
let references_parse_to_sources () =
  List.iter
    (fun (reference, expected) ->
      match Secret.of_reference reference with
      | Error reason -> Alcotest.failf "%s: %s" reference reason
      | Ok secret ->
          Alcotest.(check string) reference expected (Secret.describe secret))
    [
      ("keychain:ade-work-ssh", "keychain item ade-work-ssh");
      ("file:/etc/ade/key.pem", "file /etc/ade/key.pem");
      (* A bare path keeps existing declarations working. *)
      ("/etc/ade/key.pem", "file /etc/ade/key.pem");
    ]

let malformed_references_are_rejected () =
  List.iter
    (fun reference ->
      match Secret.of_reference reference with
      | Ok _ -> Alcotest.failf "expected %S to be rejected" reference
      | Error _ -> ())
    [ ""; "keychain:"; "file:"; "vault:something" ]

(* Runtime guarantee: describe is the only string-returning function, and it
   cannot leak because the credential has not been read. *)
let describe_names_the_location_not_the_value () =
  let secret = Secret.keychain ~item:"ade-work-ssh" in
  let described = Secret.describe secret in
  Alcotest.(check bool) "names the item" true (contains described "ade-work-ssh");
  Alcotest.(check bool) "no credential" false (contains described payload)

let the_value_reaches_the_callback () =
  let seen = ref None in
  let secret = Secret.keychain ~item:"item" in
  match
    Secret.with_value ~reader:(reader_returning payload) secret ~f:(fun value ->
        seen := Some value;
        Ok ())
  with
  | Error e -> Alcotest.failf "with_value: %s" (Ade_error.to_string e)
  | Ok () -> Alcotest.(check (option string)) "delivered" (Some payload) !seen

(* A failing read must surface as an error rather than a silent empty value,
   which a caller could mistake for a valid empty credential. *)
let a_failed_read_is_reported () =
  let reader _ =
    Error (Ade_error.Operation_refused { operation = "read"; reason = "absent" })
  in
  let called = ref false in
  match
    Secret.with_value ~reader (Secret.keychain ~item:"missing") ~f:(fun _ ->
        called := true;
        Ok ())
  with
  | Ok () -> Alcotest.fail "expected a failed read to be reported"
  | Error _ -> Alcotest.(check bool) "callback not run" false !called

let a_missing_file_is_reported () =
  let secret = Secret.file ~path:"/nonexistent/ade/key.pem" in
  match
    Secret.with_value ~reader:(Secret.default_reader ~runner:Process_runner.run) secret
      ~f:(fun _ -> Ok ())
  with
  | Ok () -> Alcotest.fail "expected a missing file to be reported"
  | Error error ->
      Alcotest.(check bool) "names the path" true
        (contains (Ade_error.to_string error) "/nonexistent/ade/key.pem")

let a_real_file_is_read () =
  let path = Filename.temp_file "ade-secret-" ".txt" in
  let channel = open_out path in
  output_string channel payload;
  close_out channel;
  let seen = ref None in
  match
    Secret.with_value ~reader:(Secret.default_reader ~runner:Process_runner.run)
      (Secret.file ~path) ~f:(fun value ->
        seen := Some value;
        Ok ())
  with
  | Error e -> Alcotest.failf "read: %s" (Ade_error.to_string e)
  | Ok () -> Alcotest.(check (option string)) "contents" (Some payload) !seen

(* The keychain reader passes the item name as an argument, which is a
   locator, and receives the credential on stdout. The credential must never be
   an argument. *)
let the_keychain_reader_passes_only_a_locator () =
  let seen = ref [] in
  let runner request =
    seen := request.Process_runner.argv;
    Ok { Process_runner.status = 0; stdout = payload ^ "\n"; stderr = "" }
  in
  let reader = Secret.default_reader ~runner in
  match
    Secret.with_value ~reader (Secret.keychain ~item:"ade-work-ssh") ~f:(fun value ->
        (* security appends a newline the credential does not include. *)
        Alcotest.(check string) "trimmed" payload value;
        Ok ())
  with
  | Error e -> Alcotest.failf "keychain: %s" (Ade_error.to_string e)
  | Ok () ->
      List.iter
        (fun argument ->
          if contains argument payload then
            Alcotest.failf "the credential appeared in argv: %s" argument)
        !seen;
      Alcotest.(check bool) "names the item" true
        (List.exists (fun a -> a = "ade-work-ssh") !seen)

let () =
  Alcotest.run "secret"
    [ ( "references",
        [ Alcotest.test_case "parse" `Quick references_parse_to_sources;
          Alcotest.test_case "malformed" `Quick malformed_references_are_rejected ] );
      ( "diagnostics",
        [ Alcotest.test_case "describe" `Quick describe_names_the_location_not_the_value ] );
      ( "reading",
        [ Alcotest.test_case "callback" `Quick the_value_reaches_the_callback;
          Alcotest.test_case "failure" `Quick a_failed_read_is_reported;
          Alcotest.test_case "missing file" `Quick a_missing_file_is_reported;
          Alcotest.test_case "real file" `Quick a_real_file_is_read;
          Alcotest.test_case "keychain locator" `Quick
            the_keychain_reader_passes_only_a_locator ] )
    ]
