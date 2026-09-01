open Ade

let render = function
  | Provider.Mints_short_lived -> "mints"
  | Provider.Manually_managed _ -> "manual"
  | Provider.Not_ade_managed _ -> "unmanaged"

(* The design is explicit that only some providers support minting. Claiming
   otherwise in status output would mislead the user into expecting rotation
   that never happens. *)
let rotation_is_honest_per_provider () =
  List.iter
    (fun (provider, expected) ->
      Alcotest.(check string)
        (Credential.provider_to_string provider)
        expected
        (render (Provider.rotation_of provider)))
    [
      (Credential.Github, "mints");
      (Credential.Kubernetes, "mints");
      (Credential.Ssh, "manual");
      (Credential.Datadog, "manual");
      (Credential.Circleci, "manual");
    ]

let every_non_minting_provider_explains_itself () =
  List.iter
    (fun provider ->
      match Provider.rotation_of provider with
      | Provider.Mints_short_lived -> ()
      | Provider.Manually_managed { reason } | Provider.Not_ade_managed { reason } ->
          Alcotest.(check bool)
            (Credential.provider_to_string provider ^ " gives a reason")
            true
            (String.length reason > 0))
    [ Credential.Github; Credential.Kubernetes; Credential.Ssh;
      Credential.Datadog; Credential.Circleci ]

(* An unscoped credential would carry the provider's default authority. *)
let unscoped_requests_are_refused () =
  let request = Provider.github_request ~repositories:[] ~lifetime_seconds:3600.0 in
  match Provider.validate_scope request with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected an unscoped request to be refused"

let scoped_requests_are_accepted () =
  let request =
    Provider.github_request ~repositories:[ "owner/repo" ] ~lifetime_seconds:3600.0
  in
  match Provider.validate_scope request with
  | Ok () -> ()
  | Error e -> Alcotest.failf "unexpected refusal: %s" (Ade_error.to_string e)

let non_positive_lifetimes_are_refused () =
  let request =
    Provider.github_request ~repositories:[ "owner/repo" ] ~lifetime_seconds:0.0
  in
  match Provider.validate_scope request with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected a zero lifetime to be refused"

let kubernetes_scope_records_audience_and_namespace () =
  let request =
    Provider.kubernetes_request ~audience:"api" ~namespace:"team" ~lifetime_seconds:600.0
  in
  Alcotest.(check (list string)) "scope"
    [ "audience=api"; "namespace=team" ] request.Provider.scope

let () =
  Alcotest.run "provider"
    [ ( "rotation",
        [ Alcotest.test_case "honest" `Quick rotation_is_honest_per_provider;
          Alcotest.test_case "explained" `Quick every_non_minting_provider_explains_itself ] );
      ( "scope",
        [ Alcotest.test_case "unscoped refused" `Quick unscoped_requests_are_refused;
          Alcotest.test_case "scoped accepted" `Quick scoped_requests_are_accepted;
          Alcotest.test_case "lifetime" `Quick non_positive_lifetimes_are_refused;
          Alcotest.test_case "kubernetes" `Quick
            kubernetes_scope_records_audience_and_namespace ] )
    ]
