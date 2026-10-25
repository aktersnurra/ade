type step = Signed | Exchanged | Installed | Activated

let describe_step = function
  | Signed -> "signed"
  | Exchanged -> "exchanged"
  | Installed -> "installed"
  | Activated -> "activated"

type rotation = { steps : step list; generation : Credential.generation }

let ( let* ) = Result.bind

let github_error error = Ade_error.Github_failed error

let rotate_github ?http ?runner ~smolvm ~name ~config ~now ~previous () =
  let runner = match runner with Some r -> r | None -> Process_runner.run in
  let http =
    match http with
    | Some http -> http
    | None -> fun ~url ~bearer ~body -> Http.post ~runner ~url ~bearer ~body ()
  in
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
  (* Only the exchange can construct the installer's verified credential. *)
  let* installed =
    Credential_installer.install ~smolvm ~name ~credential:minted ~now ~previous
  in
  Ok
    {
      steps = [ Signed; Exchanged; Installed; Activated ];
      generation = installed.Credential_installer.generation;
    }
