open Ade

let now = 1_756_500_000.0

(* Fixture values are assembled at runtime so nothing in this file resembles a
   real credential. *)
let fake_token = "FAKE" ^ "-installation-token"

let key_path () =
  (* validate only checks that the path exists; contents are never read. *)
  let path = Filename.temp_file "ade-app-key-" ".pem" in
  let channel = open_out path in
  output_string channel "placeholder fixture\n";
  close_out channel;
  path

let config ?(repositories = [ "owner/repo" ]) ?(permissions = [ ("contents", "write") ])
    ?private_key_path () =
  {
    Github_credential.app_id = "123456";
    installation_id = "78901234";
    private_key =
      Secret.file ~path:(match private_key_path with Some p -> p | None -> key_path ());
    repositories;
    permissions;
  }

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let expect_invalid label result =
  match result with
  | Ok () -> Alcotest.failf "%s: expected a refusal" label
  | Error _ -> ()

(* An unscoped token reaches every repository the App is installed on. *)
let a_config_without_repositories_is_refused () =
  expect_invalid "no repositories"
    (Github_credential.validate (config ~repositories:[] ()))

let a_config_without_permissions_is_refused () =
  expect_invalid "no permissions"
    (Github_credential.validate (config ~permissions:[] ()))

(* A key reference names a location; whether it resolves is a read-time
   concern. Validation accepts it, and an unreadable key surfaces at signing
   with the path named. *)
let a_key_reference_is_not_resolved_at_validation () =
  match
    Github_credential.validate (config ~private_key_path:"/nonexistent/key.pem" ())
  with
  | Ok () -> ()
  | Error e -> Alcotest.failf "unexpected: %s" (Github_credential.describe_error e)

let a_complete_config_is_accepted () =
  match Github_credential.validate (config ()) with
  | Ok () -> ()
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

let ok_post body ~url:_ ~bearer:_ = Ok (201, body)

let a_successful_exchange_yields_a_token_and_expiry () =
  let body =
    Printf.sprintf {|{"token":"%s","expires_at":"2026-08-29T23:00:00Z"}|} fake_token
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Error e -> Alcotest.failf "exchange: %s" (Github_credential.describe_error e)
  | Ok minted ->
      Alcotest.(check string) "token" fake_token minted.Provider.value;
      Alcotest.(check bool) "expiry parsed as a real time" true
        (minted.Provider.expires_at > 1_756_000_000.0)

(* A refusal must be reported as such, not silently treated as a token. *)
let a_refused_exchange_is_reported () =
  let post ~url:_ ~bearer:_ = Ok (401, {|{"message":"unauthorized"}|}) in
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

(* Without a readable expiry, assume the shorter horizon: treating an unknown
   expiry as far away would keep a dead credential in use. *)
let an_unreadable_expiry_falls_back_to_one_hour () =
  let body =
    Printf.sprintf {|{"token":"%s","expires_at":"not-a-timestamp"}|} fake_token
  in
  match Github_credential.exchange ~post:(ok_post body) (config ()) ~jwt:"jwt" ~now with
  | Ok minted ->
      Alcotest.(check (float 1.0)) "one hour" (now +. 3600.0) minted.Provider.expires_at
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

let () =
  Alcotest.run "github_credential"
    [ ( "configuration",
        [ Alcotest.test_case "no repositories" `Quick a_config_without_repositories_is_refused;
          Alcotest.test_case "no permissions" `Quick a_config_without_permissions_is_refused;
          Alcotest.test_case "key reference" `Quick
            a_key_reference_is_not_resolved_at_validation;
          Alcotest.test_case "complete" `Quick a_complete_config_is_accepted ] );
      ( "request",
        [ Alcotest.test_case "jwt window" `Quick the_jwt_window_satisfies_github;
          Alcotest.test_case "token url" `Quick the_token_url_names_the_installation ] );
      ( "exchange",
        [ Alcotest.test_case "success" `Quick a_successful_exchange_yields_a_token_and_expiry;
          Alcotest.test_case "refusal" `Quick a_refused_exchange_is_reported;
          Alcotest.test_case "malformed" `Quick a_malformed_response_is_reported;
          Alcotest.test_case "expiry fallback" `Quick
            an_unreadable_expiry_falls_back_to_one_hour ] );
      ( "encoding",
        [ Alcotest.test_case "vectors" `Quick base64url_matches_the_spec;
          Alcotest.test_case "url safe" `Quick
            base64url_never_emits_padding_or_unsafe_characters ] );
      ( "signing",
        [ Alcotest.test_case "input" `Quick the_signing_input_has_two_dot_separated_segments;
          Alcotest.test_case "three segments" `Quick a_signed_jwt_has_three_segments;
          Alcotest.test_case "failure" `Quick a_signing_failure_is_reported ] )
    ]
