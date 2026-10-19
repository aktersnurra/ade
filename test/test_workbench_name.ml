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
            (rejects (Workbench_name.Too_long 65) (String.make 65 'a')) ] )
    ]
