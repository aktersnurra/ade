open Ade

let now = 1_756_500_000.0
let margin = 300.0

let generation expires_at =
  Some { Credential.number = 1; provider = Credential.Github; expires_at; installed_at = now }

let decide ~running ~generation =
  Credential_schedule.decide ~now ~margin_seconds:margin ~running ~generation

let render = function
  | Credential_schedule.Skip_not_running -> "skip-not-running"
  | Credential_schedule.Skip_healthy -> "skip-healthy"
  | Credential_schedule.Rotate -> "rotate"

let check label expected actual = Alcotest.(check string) label expected (render actual)

(* rotate --due rotates only running workbenches. *)
let a_stopped_workbench_is_skipped () =
  check "stopped" "skip-not-running"
    (decide ~running:false ~generation:(generation (now -. 10.0)))

let a_healthy_generation_is_skipped () =
  check "healthy" "skip-healthy" (decide ~running:true ~generation:(generation (now +. 3600.0)))

let an_expiring_generation_rotates () =
  check "expiring" "rotate" (decide ~running:true ~generation:(generation (now +. 60.0)))

let an_expired_generation_rotates () =
  check "expired" "rotate" (decide ~running:true ~generation:(generation (now -. 60.0)))

(* A running workbench with no generation needs one before dependent agents. *)
let a_running_workbench_without_a_generation_rotates () =
  check "missing" "rotate" (decide ~running:true ~generation:None)

let every_decision_has_a_description () =
  List.iter
    (fun decision ->
      Alcotest.(check bool) "described" true
        (String.length (Credential_schedule.describe decision) > 0))
    [
      Credential_schedule.Skip_not_running;
      Credential_schedule.Skip_healthy;
      Credential_schedule.Rotate;
    ]

let the_plist_invokes_a_bounded_rotation () =
  let plist =
    Credential_schedule.launchd_plist ~label:"io.ade.credentials"
      ~ade_path:"/usr/local/bin/ade" ~interval_seconds:900
  in
  let contains needle =
    let hl = String.length plist and nl = String.length needle in
    let rec scan i = i + nl <= hl && (String.sub plist i nl = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "label" true (contains "io.ade.credentials");
  Alcotest.(check bool) "invokes rotate --due" true (contains "--due");
  Alcotest.(check bool) "interval" true (contains "<integer>900</integer>");
  (* No daemon: each invocation exits, and nothing keeps it alive. *)
  Alcotest.(check bool) "no KeepAlive" false (contains "KeepAlive")

let () =
  Alcotest.run "credential_schedule"
    [ ( "due",
        [ Alcotest.test_case "stopped" `Quick a_stopped_workbench_is_skipped;
          Alcotest.test_case "healthy" `Quick a_healthy_generation_is_skipped;
          Alcotest.test_case "expiring" `Quick an_expiring_generation_rotates;
          Alcotest.test_case "expired" `Quick an_expired_generation_rotates;
          Alcotest.test_case "missing" `Quick a_running_workbench_without_a_generation_rotates;
          Alcotest.test_case "described" `Quick every_decision_has_a_description ] );
      ( "launchd",
        [ Alcotest.test_case "plist" `Quick the_plist_invokes_a_bounded_rotation ] )
    ]
