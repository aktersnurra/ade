open Ade

let now = 1_756_500_000.0
let minted_token = "FAKE" ^ "-minted-installation-token"
let key_material = "FAKE" ^ "-app-private-key"
let signature = "FAKE" ^ "-rsa-signature"

let key_path () =
  let path = Filename.temp_file "ade-flow-key-" ".pem" in
  let channel = open_out path in
  output_string channel key_material;
  close_out channel;
  path

let config ?(repositories = [ "owner/repo" ]) ?(permissions = [ ("contents", "write") ]) () =
  {
    Github_credential.app_id = "123456";
    installation_id = "78901234";
    private_key = Secret.file ~path:(key_path ());
    repositories;
    permissions;
  }

let name_exn value =
  match Workbench_name.of_string value with
  | Ok n -> n
  | Error _ -> Alcotest.failf "bad name %s" value

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

type fake = { mutable requests : Process_runner.request list }

(* One runner stands in for the whole host: openssl signs, smolvm exec accepts
   the install, and anything else succeeds quietly. *)
let runner fake request =
  fake.requests <- fake.requests @ [ request ];
  let executable = Filename.basename request.Process_runner.executable in
  if executable = "openssl" then
    Ok { Process_runner.status = 0; stdout = signature; stderr = "" }
  else Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let setup () =
  let fake = { requests = [] } in
  let run = runner fake in
  (fake, run, Smolvm.make ~executable:"/usr/bin/true" ~runner:run)

let ok_http body ~url:_ ~bearer:_ = Ok (201, body)

let token_body =
  Printf.sprintf {|{"token":"%s","expires_at":"2025-08-29T21:40:00Z"}|} minted_token

let rotate ?(http = ok_http token_body) ?config:c ?previous () =
  let fake, run, smolvm = setup () in
  let config = match c with Some c -> c | None -> config () in
  ( fake,
    Credential_flow.rotate_github ~http ~runner:run ~smolvm
      ~name:(name_exn "work") ~config ~now ~previous () )

let a_full_rotation_completes_every_step () =
  let _, result = rotate () in
  match result with
  | Error e -> Alcotest.failf "rotate: %s" (Ade_error.to_string e)
  | Ok rotation ->
      Alcotest.(check (list string)) "steps"
        [ "signed"; "exchanged"; "installed"; "activated" ]
        (List.map Credential_flow.describe_step rotation.Credential_flow.steps)

let the_generation_records_the_minted_expiry () =
  let _, result = rotate () in
  match result with
  | Error e -> Alcotest.failf "rotate: %s" (Ade_error.to_string e)
  | Ok rotation ->
      let generation = rotation.Credential_flow.generation in
      Alcotest.(check int) "first generation" 1 generation.Credential.number;
      Alcotest.(check bool) "expiry in the future" true
        (generation.Credential.expires_at > now)

(* Neither the App key nor the minted token may reach a command line: any local
   process can read argv from the process table. *)
let no_secret_reaches_argv_or_the_environment () =
  let fake, _ = rotate () in
  List.iter
    (fun request ->
      List.iter
        (fun argument ->
          List.iter
            (fun (label, secret) ->
              if contains argument secret then
                Alcotest.failf "%s appeared in argv: %s" label argument)
            [ ("the app key", key_material); ("the minted token", minted_token) ])
        request.Process_runner.argv;
      List.iter
        (fun (key, value) ->
          List.iter
            (fun (label, secret) ->
              if contains value secret then
                Alcotest.failf "%s appeared in the environment as %s" label key)
            [ ("the app key", key_material); ("the minted token", minted_token) ])
        request.Process_runner.env)
    fake.requests

let the_minted_token_is_delivered_on_stdin () =
  let fake, _ = rotate () in
  Alcotest.(check bool) "token installed via stdin" true
    (List.exists
       (fun r -> r.Process_runner.stdin = Some minted_token)
       fake.requests)

(* An over-broad configuration must be refused before GitHub is contacted. *)
let an_unscoped_configuration_never_reaches_github () =
  let contacted = ref false in
  let http ~url:_ ~bearer:_ =
    contacted := true;
    Ok (201, token_body)
  in
  let _, result = rotate ~http ~config:(config ~repositories:[] ()) () in
  (match result with
   | Ok _ -> Alcotest.fail "expected an unscoped configuration to be refused"
   | Error _ -> ());
  Alcotest.(check bool) "github not contacted" false !contacted

(* A refused exchange must not install anything: the previous generation stays
   active rather than being replaced by nothing. *)
let a_refused_exchange_installs_nothing () =
  let http ~url:_ ~bearer:_ = Ok (401, {|{"message":"unauthorized"}|}) in
  let fake, result = rotate ~http () in
  (match result with
   | Ok _ -> Alcotest.fail "expected a 401 to fail the rotation"
   | Error _ -> ());
  Alcotest.(check bool) "nothing installed" false
    (List.exists
       (fun r -> r.Process_runner.stdin = Some minted_token)
       fake.requests)

let a_transport_failure_is_reported () =
  let http ~url:_ ~bearer:_ = Error "connection refused" in
  let _, result = rotate ~http () in
  match result with
  | Ok _ -> Alcotest.fail "expected a transport failure to be reported"
  | Error error ->
      Alcotest.(check bool) "keeps the cause" true
        (contains (Ade_error.to_string error) "connection refused")

let generations_advance_across_rotations () =
  let previous =
    {
      Credential.number = 4;
      provider = Credential.Github;
      expires_at = now;
      installed_at = now;
    }
  in
  let _, result = rotate ~previous () in
  match result with
  | Error e -> Alcotest.failf "rotate: %s" (Ade_error.to_string e)
  | Ok rotation ->
      Alcotest.(check int) "next generation" 5
        rotation.Credential_flow.generation.Credential.number

let () =
  Alcotest.run "credential_flow"
    [ ( "rotation",
        [ Alcotest.test_case "all steps" `Quick a_full_rotation_completes_every_step;
          Alcotest.test_case "expiry" `Quick the_generation_records_the_minted_expiry;
          Alcotest.test_case "generations" `Quick generations_advance_across_rotations ] );
      ( "secrecy",
        [ Alcotest.test_case "not in argv or env" `Quick
            no_secret_reaches_argv_or_the_environment;
          Alcotest.test_case "token on stdin" `Quick
            the_minted_token_is_delivered_on_stdin ] );
      ( "failures",
        [ Alcotest.test_case "unscoped refused early" `Quick
            an_unscoped_configuration_never_reaches_github;
          Alcotest.test_case "refused exchange" `Quick a_refused_exchange_installs_nothing;
          Alcotest.test_case "transport" `Quick a_transport_failure_is_reported ] )
    ]
