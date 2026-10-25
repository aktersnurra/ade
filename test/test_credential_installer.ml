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

let install fake_smolvm ?(value = secret) ?(expires_at = now +. 3600.0) ?previous () =
  let config = Result.get_ok (Github_credential.validate
      { app_id = "1"; installation_id = "2"; private_key = Secret.file ~path:"unused";
        repositories = [ "repo" ]; permissions = [ "contents", "write" ] }) in
  let date = Unix.gmtime expires_at in
  let expiry = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (date.tm_year + 1900) (date.tm_mon + 1) date.tm_mday date.tm_hour date.tm_min date.tm_sec in
  let body = Yojson.Safe.to_string (`Assoc [ "token", `String value; "expires_at", `String expiry;
      "repository_selection", `String "selected";
      "repositories", `List [ `Assoc [ "name", `String "repo" ] ];
      "permissions", `Assoc [ "contents", `String "write" ] ]) in
  match Github_credential.exchange ~post:(fun ~url:_ ~bearer:_ ~body:_ -> Ok (201, body))
      config ~jwt:"fake" ~now with
  | Error error -> Error (Ade_error.Runtime_output_invalid
      { context = "credential"; reason = Github_credential.describe_error error })
  | Ok credential -> Credential_installer.install ~smolvm:fake_smolvm ~name:(name_exn "work")
      ~credential ~now ~previous

(* A guest command that exits nonzero is a failed install, not a success with
   an empty result: reporting an activated generation that was never written
   would leave the agents without the credential they were promised. *)
let failing_runner _ =
  Ok { Process_runner.status = 1; stdout = ""; stderr = "No space left on device" }

let a_failed_guest_command_fails_the_install () =
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:failing_runner in
  match
    install smolvm ()
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

let generated_tokens_stay_on_stdin () =
  Hegel.run_hegel_test ~database_key:"credential-transport" (fun tc ->
      let bytes = Hegel.draw ~label:"token bytes" tc (Hegel.Generators.binary ()) in
      let secret = "HEGEL_SECRET_" ^ bytes ^ "_END" in
      let fake, smolvm = setup () in
      (match install smolvm ~value:secret () with
       | Ok _ -> () | Error error -> Alcotest.fail (Ade_error.to_string error));
      Hegel.require tc (List.exists (fun r -> r.Process_runner.stdin = Some secret) fake.requests);
      List.iter (fun request ->
          Hegel.require tc (not (List.exists (fun arg -> contains arg secret) request.Process_runner.argv));
          Hegel.require tc (not (List.exists (fun (_, value) -> contains value secret) request.env));
          Hegel.require tc (not (contains (Process_runner.render_for_diagnostics request) secret))) fake.requests)

let installation_preserves_the_previous_generation_until_activation () =
  let root = Filename.temp_file "ade-guest-secrets-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  let fail_activation = ref false in
  let relocate script =
    let needle = Credential_installer.secrets_root in
    let buffer = Buffer.create (String.length script) in
    let rec copy i =
      if i < String.length script then
        if i + String.length needle <= String.length script
           && String.sub script i (String.length needle) = needle then
          (Buffer.add_string buffer root; copy (i + String.length needle))
        else (Buffer.add_char buffer script.[i]; copy (i + 1)) in
    copy 0; Buffer.contents buffer in
  let runner request =
    match List.rev request.Process_runner.argv with
    | script :: "-c" :: "sh" :: _ ->
        if !fail_activation && contains script "ln -sfn" then
          Ok { Process_runner.status = 1; stdout = ""; stderr = "activation failed" }
        else Process_runner.run { request with executable = "/bin/sh"; argv = [ "-c"; relocate script ] }
    | _ -> Alcotest.fail "unexpected guest command" in
  let smolvm = Smolvm.make ~executable:"fake" ~runner in
  let read path = In_channel.with_open_bin (Filename.concat root path) In_channel.input_all in
  Fun.protect ~finally:(fun () -> ignore (Bos.OS.Dir.delete ~recurse:true (Fpath.v root))) (fun () ->
      let first = Result.get_ok (install smolvm ~value:"first" ()) in
      Alcotest.(check string) "first active" "first" (read "current/github");
      fail_activation := true;
      Alcotest.(check bool) "activation fails" true
        (Result.is_error (install smolvm ~value:"second" ~previous:first.generation ()));
      Alcotest.(check string) "previous preserved" "first" (read "current/github");
      fail_activation := false;
      ignore (Result.get_ok (install smolvm ~value:"second" ~previous:first.generation ()));
      Alcotest.(check string) "new generation active" "second" (read "current/github");
      Alcotest.(check string) "old generation immutable" "first" (read "generation-1/github"))

let () =
  Alcotest.run "credential_installer"
    [ ( "secrecy",
        [ Alcotest.test_case "transport property" `Quick generated_tokens_stay_on_stdin;
          Alcotest.test_case "not in argv" `Quick the_secret_never_reaches_argv;
          Alcotest.test_case "not in env" `Quick the_secret_never_reaches_the_environment;
          Alcotest.test_case "on stdin" `Quick the_secret_travels_on_stdin;
          Alcotest.test_case "not in diagnostics" `Quick diagnostics_stay_secret_free ] );
      ( "installation",
        [ Alcotest.test_case "real activation" `Quick installation_preserves_the_previous_generation_until_activation;
          Alcotest.test_case "tmpfs" `Quick generations_are_written_under_tmpfs;
          Alcotest.test_case "refuses invalid" `Quick
            invalid_credentials_are_refused_before_the_guest_is_touched;
          Alcotest.test_case "numbering" `Quick generation_numbers_increase;
          Alcotest.test_case "atomic" `Quick activation_is_atomic;
          Alcotest.test_case "failed install" `Quick
            a_failed_guest_command_fails_the_install;
          Alcotest.test_case "failed revoke" `Quick a_failed_revoke_fails ] )
    ]
