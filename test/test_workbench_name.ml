open Ade

let name_error = Alcotest.testable
  (fun fmt -> function
    | Workbench_name.Empty -> Format.fprintf fmt "Empty"
    | Workbench_name.Invalid_character c -> Format.fprintf fmt "Invalid_character %c" c
    | Workbench_name.Too_long n -> Format.fprintf fmt "Too_long %d" n)
  ( = )

let accepts value () =
  match Workbench_name.of_string value with
  | Ok name -> Alcotest.(check string) "round trip" value (Workbench_name.to_string name)
  | Error _ -> Alcotest.failf "expected %s to be accepted" value

let rejects expected value () =
  match Workbench_name.of_string value with
  | Ok _ -> Alcotest.failf "expected %s to be rejected" (String.escaped value)
  | Error actual -> Alcotest.check name_error "reason" expected actual

(* Property: parsing arbitrary text never raises. of_string is a
   parse-don't-validate boundary, so garbage input must produce an error value,
   never an exception. Full Unicode text is used deliberately: multi-byte
   characters are exactly where a byte-oriented scanner goes wrong. *)
let%hegel_test parsing_never_raises tc =
  let value = Hegel.Generators.(draw tc (text ())) in
  match Workbench_name.of_string value with
  | exception exn ->
      Hegel.note tc (Printf.sprintf "raised on %S" value);
      Alcotest.failf "of_string raised on %S: %s" value (Printexc.to_string exn)
  | Ok _ | Error _ -> ()

(* Property: every accepted name round-trips through to_string unchanged.
   of_string must never silently normalize a name, because the name is used as
   both a SmolVM machine name and a host path component. *)
let%hegel_test accepted_names_round_trip tc =
  let value = Hegel.Generators.(draw tc (text ())) in
  match Workbench_name.of_string value with
  | Error _ -> ()
  | Ok name ->
      Alcotest.(check string) "round trip" value (Workbench_name.to_string name)

(* Property: acceptance is exactly the documented character set and length
   bound. This is an independent restatement of the contract, so an
   implementation that widened or narrowed its alphabet would fail here. *)
let%hegel_test acceptance_matches_contract tc =
  let value = Hegel.Generators.(draw tc (text ())) in
  let permitted c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_'
  in
  let should_accept =
    String.length value > 0
    && String.length value <= 64
    && String.for_all permitted value
  in
  let accepted = match Workbench_name.of_string value with Ok _ -> true | Error _ -> false in
  Hegel.note tc (Printf.sprintf "value=%S accepted=%b" value accepted);
  Alcotest.(check bool) "acceptance matches contract" should_accept accepted

let () =
  Alcotest.run "workbench_name"
    [ ( "valid",
        [ Alcotest.test_case "simple" `Quick (accepts "work");
          Alcotest.test_case "hyphenated" `Quick (accepts "work-cloud");
          Alcotest.test_case "digits" `Quick (accepts "work2") ] );
      ( "invalid",
        [ Alcotest.test_case "empty" `Quick (rejects Workbench_name.Empty "");
          Alcotest.test_case "space" `Quick
            (rejects (Workbench_name.Invalid_character ' ') "work bench");
          Alcotest.test_case "slash" `Quick
            (rejects (Workbench_name.Invalid_character '/') "work/cloud");
          Alcotest.test_case "dot" `Quick
            (rejects (Workbench_name.Invalid_character '.') "..");
          Alcotest.test_case "too long" `Quick
            (rejects (Workbench_name.Too_long 65) (String.make 65 'a')) ] );
      ( "properties",
        [ Alcotest.test_case "never raises" `Quick parsing_never_raises;
          Alcotest.test_case "round trips" `Quick accepted_names_round_trip;
          Alcotest.test_case "matches contract" `Quick acceptance_matches_contract ] )
    ]
