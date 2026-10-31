open Ade

let now = 1_756_500_000.0

(* Fixture values are assembled at runtime so nothing in this file resembles a
   real credential. *)
let fake_token = "FAKE" ^ "-installation-token"

let fake_pem = "-----BEGIN " ^ "PRIVATE KEY-----\nfixture\n-----END " ^ "PRIVATE KEY-----\n"

let key_path () =
  (* Configuration parsing keeps the locator; it never resolves the key. *)
  let path = Filename.temp_file "ade-app-key-" ".pem" in
  let channel = open_out path in
  output_string channel "placeholder fixture\n";
  close_out channel;
  path

let input ?(repositories = [ "owner/repo" ]) ?(permissions = [ ("contents", "write") ])
    ?private_key_path () =
  {
    Github_credential.app_id = "123456";
    installation_id = "78901234";
    private_key =
      Secret.file ~path:(match private_key_path with Some p -> p | None -> key_path ());
    repositories;
    permissions;
  }

let config ?repositories ?permissions ?private_key_path () =
  match Github_credential.validate (input ?repositories ?permissions ?private_key_path ()) with
  | Ok config -> config
  | Error error -> Alcotest.fail (Github_credential.describe_error error)

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let expect_invalid label result =
  match result with
  | Ok _ -> Alcotest.failf "%s: expected a refusal" label
  | Error _ -> ()

(* An unscoped token reaches every repository the App is installed on. *)
let a_config_without_repositories_is_refused () =
  expect_invalid "no repositories"
    (Github_credential.validate (input ~repositories:[] ()))

let a_config_without_permissions_is_refused () =
  expect_invalid "no permissions"
    (Github_credential.validate (input ~permissions:[] ()))

(* A key reference names a location; whether it resolves is a read-time
   concern. Validation accepts it, and an unreadable key surfaces at signing
   with the path named. *)
let a_key_reference_is_not_resolved_at_validation () =
  match
    Github_credential.validate (input ~private_key_path:"/nonexistent/key.pem" ())
  with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)

let a_complete_config_is_accepted () =
  match Github_credential.validate (input ()) with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)

(* GitHub rejects a JWT whose iat is ahead of its own clock, and requires the
   window to stay within ten minutes. *)
let the_jwt_window_satisfies_github () =
  let claims = Github_credential.jwt_claims (config ()) ~now in
  Alcotest.(check bool) "names the app" true (contains claims {|"iss":"123456"|});
  Alcotest.(check bool) "backdates iat" true (contains claims {|"iat":1756499940|});
  Alcotest.(check bool) "expires within ten minutes" true
    (contains claims {|"exp":1756500540|})

let the_token_url_names_the_installation () =
  Alcotest.(check string) "url"
    "https://api.github.com/app/installations/78901234/access_tokens"
    (Github_credential.token_url (config ()))

let ok_post body ~url:_ ~bearer:_ ~body:_ = Ok (201, body)

let a_successful_exchange_yields_a_token_and_expiry () =
  let body =
    Printf.sprintf {|{"token":"%s","expires_at":"2025-08-29T21:40:00Z","repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"write","metadata":"read"}}|} fake_token
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Error e -> Alcotest.failf "exchange: %s" (Github_credential.describe_error e)
  | Ok minted ->
      Alcotest.(check string) "token" fake_token minted.Github_credential.value;
      Alcotest.(check bool) "expiry parsed as a real time" true
        (minted.Github_credential.expires_at > 1_756_000_000.0)

(* A refusal must be reported as such, not silently treated as a token. *)
let a_refused_exchange_is_reported () =
  let post ~url:_ ~bearer:_ ~body:_ = Ok (401, {|{"message":"unauthorized"}|}) in
  match Github_credential.exchange ~post (config ()) ~jwt:"jwt" ~now with
  | Error (Github_credential.Exchange_failed { status; _ }) ->
      Alcotest.(check int) "status" 401 status
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.fail "expected a 401 to be reported as a failure"

let a_malformed_response_is_reported () =
  match
    Github_credential.exchange ~post:(ok_post "{not json") (config ()) ~jwt:"jwt" ~now
  with
  | Error (Github_credential.Malformed_response _) -> ()
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.fail "expected malformed JSON to be reported"

let an_unreadable_expiry_is_refused () =
  let body =
    Printf.sprintf {|{"token":"%s","expires_at":"not-a-timestamp","repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"write","metadata":"read"}}|} fake_token
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Error (Github_credential.Malformed_response _) -> ()
  | Error e -> Alcotest.failf "exchange: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.fail "accepted unknown expiry"


(* The scope is what the request body carries; without it GitHub grants the
   installation's full authority. *)
let the_request_body_carries_the_scope () =
  let config =
    config ~repositories:[ "owner/repo"; "owner/other" ]
      ~permissions:[ ("contents", "write"); ("pull_requests", "read") ] ()
  in
  let body = Github_credential.request_body config in
  let json = Yojson.Safe.from_string body in
      Alcotest.(check string) "repositories by name" {|["repo","other"]|}
        (Yojson.Safe.to_string (Yojson.Safe.Util.member "repositories" json));
      Alcotest.(check string) "permissions" {|{"contents":"write","pull_requests":"read"}|}
        (Yojson.Safe.to_string (Yojson.Safe.Util.member "permissions" json))

let the_exchange_sends_the_scope () =
  let sent = ref "" in
  let post ~url:_ ~bearer:_ ~body =
    sent := body;
    Ok
      ( 201,
        Printf.sprintf
          {|{"token":"%s","expires_at":"2025-08-29T21:40:00Z","repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"write","metadata":"read"}}|}
          fake_token )
  in
  match Github_credential.exchange ~post (config ()) ~jwt:"jwt" ~now with
  | Error e -> Alcotest.failf "exchange: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.(check bool) "scoped" true (contains !sent {|"repositories":["repo"]|})

(* GitHub's echo of the grant is checked, not trusted. *)
let a_broader_grant_is_discarded granted () =
  let body =
    Printf.sprintf {|{"token":"%s","expires_at":"2025-08-29T21:40:00Z",%s}|} fake_token granted
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Error (Github_credential.Scope_exceeded _) -> ()
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.fail "expected the token to be discarded"

let a_narrower_grant_is_accepted () =
  let body =
    Printf.sprintf
      {|{"token":"%s","expires_at":"2025-08-29T21:40:00Z","repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"read","metadata":"read"}}|}
      fake_token
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Ok _ -> ()
  | Error e -> Alcotest.failf "exchange: %s" (Github_credential.describe_error e)

(* base64url, not standard base64: GitHub rejects a JWT containing '+', '/' or
   '='. Vectors from RFC 4648, plus a case that exercises the substituted
   alphabet. *)
let base64url_matches_the_spec () =
  List.iter
    (fun (input, expected) ->
      Alcotest.(check string) (Printf.sprintf "%S" input) expected
        (Github_credential.base64url input))
    [
      ("", "");
      ("f", "Zg");
      ("fo", "Zm8");
      ("foo", "Zm9v");
      ("foob", "Zm9vYg");
      ("fooba", "Zm9vYmE");
      ("foobar", "Zm9vYmFy");
      (* 0xfb 0xff encodes to '+' and '/' under standard base64. *)
      ("\251\255", "-_8");
    ]

let base64url_never_emits_padding_or_unsafe_characters () =
  for length = 0 to 32 do
    let input = String.init length (fun i -> Char.chr ((i * 37) land 0xff)) in
    let encoded = Github_credential.base64url input in
    String.iter
      (fun c ->
        if c = '=' || c = '+' || c = '/' then
          Alcotest.failf "encoded output contains %c for length %d" c length)
      encoded
  done

let the_signing_input_has_two_dot_separated_segments () =
  let input = Github_credential.signing_input (config ()) ~now in
  match String.split_on_char '.' input with
  | [ header; payload ] ->
      Alcotest.(check bool) "header present" true (String.length header > 0);
      Alcotest.(check bool) "payload present" true (String.length payload > 0)
  | parts -> Alcotest.failf "expected two segments, got %d" (List.length parts)

let a_signed_jwt_has_three_segments () =
  let signer _ = Ok "raw-signature-bytes" in
  match Github_credential.sign_jwt ~signer (config ()) ~now with
  | Error e -> Alcotest.failf "sign: %s" (Github_credential.describe_error e)
  | Ok jwt ->
      Alcotest.(check int) "segments" 3 (List.length (String.split_on_char '.' jwt))

(* A signing failure must surface rather than produce a malformed token that
   GitHub would reject with a less useful error. *)
let a_signing_failure_is_reported () =
  let signer _ = Error "no such key" in
  match Github_credential.sign_jwt ~signer (config ()) ~now with
  | Error (Github_credential.Signing_failed reason) ->
      Alcotest.(check bool) "keeps the cause" true (contains reason "no such key")
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)
  | Ok _ -> Alcotest.fail "expected a signing failure to be reported"

(* The expiry must be read as UTC regardless of the host timezone. An earlier
   implementation went through Unix.mktime, which interprets the fields
   locally; it produced a time hours off and, in one direction, an expiry
   already in the past, so a freshly minted token was refused as expired. The
   exact epochs are pinned here because that bug is invisible on a UTC host. *)
let expiries_are_parsed_as_utc () =
  List.iter
    (fun (timestamp, expected) ->
      let body = Printf.sprintf {|{"token":"t","expires_at":"%s","repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"write","metadata":"read"}}|} timestamp in
      match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"j" ~now:(expected -. 60.) with
      | Error e -> Alcotest.failf "%s: %s" timestamp (Github_credential.describe_error e)
      | Ok minted ->
          Alcotest.(check (float 0.5)) timestamp expected minted.Github_credential.expires_at)
    [
      ("1970-01-01T00:00:00Z", 0.0);
      ("2000-01-01T00:00:00Z", 946684800.0);
      ("2025-08-29T21:40:00Z", 1756503600.0);
      (* A leap day, which naive month arithmetic gets wrong. *)
      ("2024-02-29T12:00:00Z", 1709208000.0);
    ]

let non_object_responses_are_errors () =
  List.iter (fun body ->
      match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"j" ~now with
      | Error _ -> () | Ok _ -> Alcotest.fail "accepted non-object")
    [ "null"; "[]"; "42"; "true"; "\"text\"" ]

let malformed_repository_entries_are_errors () =
  let body = {|{"token":"t","expires_at":"2025-08-29T21:40:00Z","repository_selection":"selected","repositories":[{}],"permissions":{"contents":"write"}}|} in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"j" ~now with
  | Error _ -> () | Ok _ -> Alcotest.fail "accepted repository without identity"

let response_decoding_is_total () =
  Hegel.run_hegel_test ~database_key:"github-json-total" (fun tc ->
      let text = Hegel.draw ~label:"text" tc (Hegel.Generators.text ()) in
      let fields = Hegel.draw ~label:"fields" tc
          (Hegel.Generators.assoc_lists (Hegel.Generators.text ()) (Hegel.Generators.text ()) ()) in
      let json = Hegel.draw_silent tc (Hegel.Generators.sampled_from
          [ `Null; `String text; `List [ `String text ];
            `Assoc (List.map (fun (key, value) -> key, `String value) fields);
            `Assoc [ "token", `String text; "repository_selection", `String "selected";
                     "repositories", `List [ `String text ] ] ]) in
      let body = if Hegel.draw tc (Hegel.Generators.booleans ()) then text else Yojson.Safe.to_string json in
      ignore (Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"j" ~now))

let accepted_responses_have_scope_and_expiry_evidence () =
  Hegel.run_hegel_test ~database_key:"github-evidence" (fun tc ->
      let has_name = Hegel.draw ~label:"has_name" tc (Hegel.Generators.booleans ()) in
      let has_expiry = Hegel.draw ~label:"has_expiry" tc (Hegel.Generators.booleans ()) in
      let repository = if Hegel.draw tc (Hegel.Generators.booleans ()) then "repo"
        else Hegel.draw ~label:"repository" tc (Hegel.Generators.text ()) in
      let permission = Hegel.draw_silent tc (Hegel.Generators.sampled_from [ "read"; "write"; "admin" ]) in
      let fields = [ "token", `String "t"; "repository_selection", `String "selected";
        "repositories", `List [ `Assoc (if has_name then [ "name", `String repository ] else []) ];
        "permissions", `Assoc [ "contents", `String permission ] ] in
      let fields = if has_expiry then ("expires_at", `String "2025-08-29T21:40:00Z") :: fields else fields in
      let result = Github_credential.exchange ~post:(ok_post (Yojson.Safe.to_string (`Assoc fields)))
          (config ()) ~jwt:"j" ~now in
      Hegel.require tc (Result.is_ok result =
        (has_name && has_expiry && repository = "repo" && permission <> "admin")))

let signing_io_failure_removes_temporary_key () =
  let key_file = ref None in
  let runner request =
    key_file := Some (List.hd (List.rev request.Process_runner.argv));
    raise (Sys_error "signer I/O failure") in
  Fun.protect ~finally:(fun () -> Option.iter (fun path ->
      try Sys.remove path with Sys_error _ -> ()) !key_file) (fun () ->
      let result = Github_credential.openssl_signer ~runner ~openssl:"unused"
          ~reader:(fun _ -> Ok fake_pem) (config ()) "input" in
      Alcotest.(check bool) "structured failure" true (Result.is_error result);
      match !key_file with
      | None -> Alcotest.fail "signer not reached"
      | Some path -> Alcotest.(check bool) "key removed" false (Sys.file_exists path))

(* A client secret or a path stored where the key belongs is refused before
   openssl sees it, by naming the reference, never by echoing the value. *)
let a_key_that_is_not_pem_is_refused_by_reference () =
  let reached = ref false in
  let runner _ = reached := true; Ok { Process_runner.status = 0; stdout = "sig"; stderr = "" } in
  let value = "0123456789abcdef0123456789abcdef01234567" in
  let config = config () in
  match Github_credential.openssl_signer ~runner ~openssl:"unused"
          ~reader:(fun _ -> Ok (value ^ "\n")) config "input" with
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error reason ->
      Alcotest.(check bool) "openssl not run" false !reached;
      Alcotest.(check bool) "says PEM" true (contains reason "PEM private key");
      Alcotest.(check bool) "names the reference" true
        (contains reason (Secret.describe (Github_credential.private_key config)));
      Alcotest.(check bool) "never echoes the value" false (contains reason value)

let () =
  Alcotest.run "github_credential"
    [ ( "configuration",
        [ Alcotest.test_case "no repositories" `Quick a_config_without_repositories_is_refused;
          Alcotest.test_case "no permissions" `Quick a_config_without_permissions_is_refused;
          Alcotest.test_case "key reference" `Quick
            a_key_reference_is_not_resolved_at_validation;
          Alcotest.test_case "complete" `Quick a_complete_config_is_accepted;
          Alcotest.test_case "admin level" `Quick (fun () ->
              expect_invalid "admin"
                (Github_credential.validate
                   (input ~permissions:[ ("administration", "admin") ] ())));
          Alcotest.test_case "unknown level" `Quick (fun () ->
              expect_invalid "level"
                (Github_credential.validate (input ~permissions:[ ("contents", "all") ] ())));
          Alcotest.test_case "several owners" `Quick (fun () ->
              expect_invalid "owners"
                (Github_credential.validate
                   (input ~repositories:[ "alice/a"; "bob/b" ] ())));
          Alcotest.test_case "malformed repository" `Quick (fun () ->
              expect_invalid "repository"
                (Github_credential.validate (input ~repositories:[ "a/b/c" ] ()))) ] );
      ( "scope",
        [ Alcotest.test_case "request body" `Quick the_request_body_carries_the_scope;
          Alcotest.test_case "sent" `Quick the_exchange_sends_the_scope;
          Alcotest.test_case "narrower accepted" `Quick a_narrower_grant_is_accepted;
          Alcotest.test_case "all repositories" `Quick
            (a_broader_grant_is_discarded
               {|"repository_selection":"all","repositories":[],"permissions":{"contents":"write"}|});
          Alcotest.test_case "extra repository" `Quick
            (a_broader_grant_is_discarded
               {|"repository_selection":"selected","repositories":[{"name":"repo"},{"name":"secret"}],"permissions":{"contents":"write"}|});
          Alcotest.test_case "extra permission" `Quick
            (a_broader_grant_is_discarded
               {|"repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"write","actions":"write"}|});
          Alcotest.test_case "higher level" `Quick
            (a_broader_grant_is_discarded
               {|"repository_selection":"selected","repositories":[{"name":"repo"}],"permissions":{"contents":"admin"}|});
          Alcotest.test_case "no scope echoed" `Quick
            (a_broader_grant_is_discarded {|"other":1|}) ] );
      ( "request",
        [ Alcotest.test_case "jwt window" `Quick the_jwt_window_satisfies_github;
          Alcotest.test_case "token url" `Quick the_token_url_names_the_installation ] );
      ( "exchange",
        [ Alcotest.test_case "total decoding property" `Quick response_decoding_is_total;
          Alcotest.test_case "evidence property" `Quick accepted_responses_have_scope_and_expiry_evidence;
          Alcotest.test_case "JSON shapes" `Quick non_object_responses_are_errors;
          Alcotest.test_case "repository shapes" `Quick malformed_repository_entries_are_errors;
          Alcotest.test_case "success" `Quick a_successful_exchange_yields_a_token_and_expiry;
          Alcotest.test_case "refusal" `Quick a_refused_exchange_is_reported;
          Alcotest.test_case "malformed" `Quick a_malformed_response_is_reported;
          Alcotest.test_case "expiry required" `Quick
            an_unreadable_expiry_is_refused;
          Alcotest.test_case "utc" `Quick expiries_are_parsed_as_utc ] );
      ( "encoding",
        [ Alcotest.test_case "vectors" `Quick base64url_matches_the_spec;
          Alcotest.test_case "url safe" `Quick
            base64url_never_emits_padding_or_unsafe_characters ] );
      ( "signing",
        [ Alcotest.test_case "I/O cleanup" `Quick signing_io_failure_removes_temporary_key;
          Alcotest.test_case "not PEM" `Quick a_key_that_is_not_pem_is_refused_by_reference;
          Alcotest.test_case "input" `Quick the_signing_input_has_two_dot_separated_segments;
          Alcotest.test_case "three segments" `Quick a_signed_jwt_has_three_segments;
          Alcotest.test_case "failure" `Quick a_signing_failure_is_reported ] )
    ]
