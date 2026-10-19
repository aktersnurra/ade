open Ade

let now = 1_756_500_000.0
let secret = "ghs_SUPERSECRETTOKENVALUE"

type fake = { mutable requests : Process_runner.request list }

let runner fake request =
  fake.requests <- fake.requests @ [ request ];
  Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let setup () =
  let fake = { requests = [] } in
  (fake, Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake))

let name_exn value =
  match Workbench_name.of_string value with
  | Ok n -> n
  | Error _ -> Alcotest.failf "bad name %s" value

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

(* A guest command that exits nonzero is a failed install, not a success with
   an empty result: reporting an activated generation that was never written
   would leave the agents without the credential they were promised. *)
let failing_runner _ =
  Ok { Process_runner.status = 1; stdout = ""; stderr = "No space left on device" }

let a_failed_guest_command_fails_the_install () =
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:failing_runner in
  match
    Credential_installer.install ~smolvm ~name:(name_exn "work")
      ~provider:Credential.Github ~value:secret ~expires_at:(now +. 3600.0) ~now
      ~previous:None
  with
  | Ok _ -> Alcotest.fail "expected the failed write to be an error"
  | Error (Ade_error.Runtime_failed { stderr; _ }) ->
      Alcotest.(check bool) "carries the guest error" true (contains stderr "No space")
  | Error e -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string e)

let a_failed_revoke_fails () =
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:failing_runner in
  match
    Credential_installer.revoke ~smolvm ~name:(name_exn "work") ~provider:Credential.Github
  with
  | Ok () -> Alcotest.fail "expected the failed revoke to be an error"
  | Error _ -> ()

let install fake_smolvm ?(value = secret) ?(expires_at = now +. 3600.0) ?previous () =
  Credential_installer.install ~smolvm:fake_smolvm ~name:(name_exn "work")
    ~provider:Credential.Github ~value ~expires_at ~now ~previous

(* The credential value must never appear in a command line: any local process
   can read argv from the process table. *)
let the_secret_never_reaches_argv () =
  let fake, smolvm = setup () in
  (match install smolvm () with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "install: %s" (Ade_error.to_string e));
  List.iter
    (fun request ->
      List.iter
        (fun argument ->
          if contains argument secret then
            Alcotest.failf "the credential appeared in argv: %s" argument)
        request.Process_runner.argv)
    fake.requests

(* It must not reach the environment either. *)
let the_secret_never_reaches_the_environment () =
  let fake, smolvm = setup () in
  ignore (install smolvm ());
  List.iter
    (fun request ->
      List.iter
        (fun (key, value) ->
          if contains value secret then
            Alcotest.failf "the credential appeared in the environment as %s" key)
        request.Process_runner.env)
    fake.requests

(* It travels on stdin instead. *)
let the_secret_travels_on_stdin () =
  let fake, smolvm = setup () in
  ignore (install smolvm ());
  let on_stdin =
    List.exists
      (fun request ->
        match request.Process_runner.stdin with
        | Some payload -> payload = secret
        | None -> false)
      fake.requests
  in
  Alcotest.(check bool) "delivered on stdin" true on_stdin

(* Diagnostics must stay secret-free even when the request carried one. *)
let diagnostics_stay_secret_free () =
  let fake, smolvm = setup () in
  ignore (install smolvm ());
  List.iter
    (fun request ->
      let rendered = Process_runner.render_for_diagnostics request in
      if contains rendered secret then
        Alcotest.failf "the credential appeared in diagnostics: %s" rendered)
    fake.requests

let generations_are_written_under_tmpfs () =
  let argv = Credential_installer.install_argv ~provider:Credential.Github ~generation:3 in
  let joined = String.concat " " argv in
  Alcotest.(check bool) "under /run/ade/secrets" true
    (contains joined "/run/ade/secrets/generation-3");
  Alcotest.(check bool) "names the provider" true (contains joined "github")

(* A failed mint must leave the working generation alone. *)
let invalid_credentials_are_refused_before_the_guest_is_touched () =
  List.iter
    (fun (label, value, expires_at) ->
      let fake, smolvm = setup () in
      match install smolvm ~value ~expires_at () with
      | Ok _ -> Alcotest.failf "%s: expected a refusal" label
      | Error _ ->
          Alcotest.(check int) (label ^ ": guest untouched") 0 (List.length fake.requests))
    [
      ("empty", "", now +. 3600.0);
      ("expired", secret, now -. 1.0);
      ("too long lived", secret, now +. (48.0 *. 3600.0));
    ]

let generation_numbers_increase () =
  let fake, smolvm = setup () in
  match install smolvm () with
  | Error e -> Alcotest.failf "install: %s" (Ade_error.to_string e)
  | Ok first -> (
      Alcotest.(check int) "first" 1 first.Credential_installer.generation.Credential.number;
      ignore fake;
      let fake2, smolvm2 = setup () in
      ignore fake2;
      match install smolvm2 ~previous:first.Credential_installer.generation () with
      | Ok second ->
          Alcotest.(check int) "second" 2
            second.Credential_installer.generation.Credential.number
      | Error e -> Alcotest.failf "second install: %s" (Ade_error.to_string e))

(* Activation must be atomic: a reader sees one whole generation or the other. *)
let activation_is_atomic () =
  let fake, smolvm = setup () in
  ignore (install smolvm ());
  let commands =
    List.concat_map (fun r -> r.Process_runner.argv) fake.requests |> String.concat " "
  in
  Alcotest.(check bool) "uses an atomic rename" true (contains commands "mv -T")

let () =
  Alcotest.run "credential_installer"
    [ ( "secrecy",
        [ Alcotest.test_case "not in argv" `Quick the_secret_never_reaches_argv;
          Alcotest.test_case "not in env" `Quick the_secret_never_reaches_the_environment;
          Alcotest.test_case "on stdin" `Quick the_secret_travels_on_stdin;
          Alcotest.test_case "not in diagnostics" `Quick diagnostics_stay_secret_free ] );
      ( "installation",
        [ Alcotest.test_case "tmpfs" `Quick generations_are_written_under_tmpfs;
          Alcotest.test_case "refuses invalid" `Quick
            invalid_credentials_are_refused_before_the_guest_is_touched;
          Alcotest.test_case "numbering" `Quick generation_numbers_increase;
          Alcotest.test_case "atomic" `Quick activation_is_atomic;
          Alcotest.test_case "failed install" `Quick
            a_failed_guest_command_fails_the_install;
          Alcotest.test_case "failed revoke" `Quick a_failed_revoke_fails ] )
    ]
