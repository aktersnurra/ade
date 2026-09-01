type rotation =
  | Mints_short_lived
  | Manually_managed of { reason : string }
  | Not_ade_managed of { reason : string }

(* Each provider is classified by what it can actually do, so status output can
   be honest instead of implying a rotation that never happens. *)
let rotation_of = function
  | Credential.Github -> Mints_short_lived
  | Credential.Kubernetes -> Mints_short_lived
  | Credential.Ssh ->
      (* ADE refreshes short-lived certificates where a CA exists, but does not
         rotate an ordinary private key on a timer. *)
      Manually_managed
        { reason = "the workbench identity is a key, not a mintable credential" }
  | Credential.Datadog ->
      Manually_managed
        { reason = "key creation requires a declared host management credential" }
  | Credential.Circleci ->
      Manually_managed
        { reason = "CircleCI exposes no API for automatic token rotation" }

let describe_rotation = function
  | Mints_short_lived -> "ADE mints short-lived credentials"
  | Manually_managed { reason } -> "manually managed: " ^ reason
  | Not_ade_managed { reason } -> "not managed by ADE: " ^ reason

type mint_request = {
  provider : Credential.provider;
  lifetime_seconds : float;
  scope : string list;
}

type minted = { value : string; expires_at : float }
type source = mint_request -> now:float -> (minted, Ade_error.t) result

let github_request ~repositories ~lifetime_seconds =
  { provider = Credential.Github; lifetime_seconds; scope = repositories }

let kubernetes_request ~audience ~namespace ~lifetime_seconds =
  {
    provider = Credential.Kubernetes;
    lifetime_seconds;
    scope = [ "audience=" ^ audience; "namespace=" ^ namespace ];
  }

let validate_scope request =
  if request.scope = [] then
    Error
      (Ade_error.Operation_refused
         {
           operation = "mint credential";
           reason =
             "no scope was declared; an unscoped credential carries whatever \
              authority the provider defaults to";
         })
  else if request.lifetime_seconds <= 0.0 then
    Error
      (Ade_error.Operation_refused
         { operation = "mint credential"; reason = "the requested lifetime is not positive" })
  else Ok ()
