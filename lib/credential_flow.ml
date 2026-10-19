type step = Signed | Exchanged | Installed | Activated

let describe_step = function
  | Signed -> "signed"
  | Exchanged -> "exchanged"
  | Installed -> "installed"
  | Activated -> "activated"

type rotation = { steps : step list; generation : Credential.generation }

let ( let* ) = Result.bind

let github_error error =
  Ade_error.Operation_refused
    { operation = "rotate github credential";
      reason = Github_credential.describe_error error }

let rotate_github ?http ?runner ~smolvm ~name ~config ~now ~previous () =
  let runner = match runner with Some r -> r | None -> Process_runner.run in
  let http =
    match http with
    | Some http -> http
    | None -> fun ~url ~bearer ~body -> Http.post ~runner ~url ~bearer ~body ()
  in
  (* Refuse an over-broad configuration before contacting GitHub at all: an
     unscoped token would carry the App's full installation authority. *)
  let* () = Result.map_error github_error (Github_credential.validate config) in

  let signer =
    Github_credential.openssl_signer ~runner ~openssl:"/usr/bin/openssl"
      ~reader:(Secret.default_reader ~runner) config
  in
  let* jwt =
    Result.map_error github_error (Github_credential.sign_jwt ~signer config ~now)
  in
  let* minted =
    Result.map_error github_error
      (Github_credential.exchange ~post:http config ~jwt ~now)
  in
  (* The token goes straight from the exchange to the installer. It is never
     returned, logged, or held anywhere it could be read back. *)
  let* installed =
    Credential_installer.install ~smolvm ~name ~provider:Credential.Github
      ~value:minted.Github_credential.value ~expires_at:minted.Github_credential.expires_at ~now
      ~previous
  in
  Ok
    {
      steps = [ Signed; Exchanged; Installed; Activated ];
      generation = installed.Credential_installer.generation;
    }
