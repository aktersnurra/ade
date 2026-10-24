open Ade

let ok stdout = Ok { Process_runner.status = 0; stdout; stderr = "" }

(* A runner that answers the two probes doctor makes. *)
let runner ~kernel request =
  match Filename.basename request.Process_runner.executable with
  | "uname" -> ok kernel
  | _ -> ok "smolvm 0.5.0\n"

let find ~present name = if List.mem name present then Some ("/bin/" ^ name) else None

let run ?(kernel = "Linux\n") ?(kvm = true)
    ?(present = [ "smolvm"; "uname"; "git"; "ssh-agent"; "ssh-add"; "pass" ]) () =
  Doctor.run ~runner:(runner ~kernel) ~find_executable:(find ~present)
    ~smolvm:"smolvm" ~kvm_usable:(fun () -> kvm)

let verdict checks name =
  (List.find (fun check -> check.Doctor.name = name) checks).Doctor.verdict

let test_all_present () =
  Alcotest.(check bool) "healthy" true (Doctor.healthy (run ()))

let test_missing_smolvm_fails () =
  let checks = run ~present:[ "uname"; "git" ] () in
  Alcotest.(check bool) "unhealthy" false (Doctor.healthy checks);
  Alcotest.(check bool) "smolvm fails" true (verdict checks "smolvm" = Doctor.Fail)

let test_no_kvm_fails_on_linux () =
  Alcotest.(check bool) "unhealthy" false (Doctor.healthy (run ~kvm:false ()))

let test_kvm_not_needed_on_macos () =
  Alcotest.(check bool) "healthy" true
    (Doctor.healthy (run ~kernel:"Darwin\n" ~kvm:false ()))

let test_missing_git_fails () =
  let present = [ "smolvm"; "uname" ] in
  Alcotest.(check bool) "unhealthy" false (Doctor.healthy (run ~present ()))

let test_optional_tools_do_not_fail () =
  let checks = run ~present:[ "smolvm"; "uname"; "git" ] () in
  Alcotest.(check bool) "healthy" true (Doctor.healthy checks);
  Alcotest.(check bool) "pass is a warning" true
    (verdict checks "pass" = Doctor.Optional_missing)

(* A secret check reads the reference and keeps only whether it worked. *)
let test_secret_checks () =
  let readable = Secret.file ~path:"/keys/ok" in
  let missing = Secret.file ~path:"/keys/missing" in
  let read secret =
    if secret == readable then Ok ()
    else Error (Ade_error.Operation_refused { operation = "read credential"; reason = "no file" })
  in
  let checks =
    Doctor.secret_checks ~read
      [ ("ssh key", Ok readable); ("github key", Ok missing);
        ("anthropic", Error "unknown secret scheme") ]
  in
  Alcotest.(check bool) "unhealthy" false (Doctor.healthy checks);
  Alcotest.(check bool) "readable passes" true (verdict checks "ssh key" = Doctor.Pass);
  Alcotest.(check bool) "unreadable fails" true (verdict checks "github key" = Doctor.Fail);
  Alcotest.(check bool) "unparsable fails" true (verdict checks "anthropic" = Doctor.Fail)

let () =
  Alcotest.run "doctor"
    [ ( "doctor",
        [ Alcotest.test_case "all present" `Quick test_all_present;
          Alcotest.test_case "missing smolvm" `Quick test_missing_smolvm_fails;
          Alcotest.test_case "no kvm on linux" `Quick test_no_kvm_fails_on_linux;
          Alcotest.test_case "no kvm on macos" `Quick test_kvm_not_needed_on_macos;
          Alcotest.test_case "missing git" `Quick test_missing_git_fails;
          Alcotest.test_case "optional tools" `Quick test_optional_tools_do_not_fail;
          Alcotest.test_case "secrets" `Quick test_secret_checks ] ) ]
