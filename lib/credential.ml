type provider = Github | Kubernetes | Ssh | Datadog | Circleci

let provider_to_string = function
  | Github -> "github"
  | Kubernetes -> "kubernetes"
  | Ssh -> "ssh"
  | Datadog -> "datadog"
  | Circleci -> "circleci"

type generation = {
  number : int;
  provider : provider;
  expires_at : float;
  installed_at : float;
}

type health =
  | Healthy
  | Expiring_soon of { seconds_remaining : float }
  | Expired of { seconds_ago : float }

(* The margin exists because host and provider clocks do not agree exactly.
   Rotating early is safe; using a credential past its real expiry is not. *)
let health_of ~now ~margin_seconds generation =
  let remaining = generation.expires_at -. now in
  if remaining <= 0.0 then Expired { seconds_ago = -.remaining }
  else if remaining <= margin_seconds then Expiring_soon { seconds_remaining = remaining }
  else Healthy

let needs_rotation ~now ~margin_seconds generation =
  match health_of ~now ~margin_seconds generation with
  | Healthy -> false
  | Expiring_soon _ | Expired _ -> true

type validation_error =
  | Empty_value
  | Already_expired
  | Expiry_too_far of { seconds : float }

(* A credential valid for longer than this is not the short-lived credential
   ADE asked for, and suggests the provider ignored the requested lifetime. *)
let maximum_lifetime_seconds = 24.0 *. 60.0 *. 60.0

let describe_validation_error = function
  | Empty_value -> "the minted credential was empty"
  | Already_expired -> "the minted credential is already expired"
  | Expiry_too_far { seconds } ->
      Printf.sprintf
        "the minted credential lasts %.0f seconds, longer than the %.0f second maximum"
        seconds maximum_lifetime_seconds

let validate ~now ~value ~expires_at =
  if String.length value = 0 then Error Empty_value
  else
    let lifetime = expires_at -. now in
    if lifetime <= 0.0 then Error Already_expired
    else if lifetime > maximum_lifetime_seconds then
      Error (Expiry_too_far { seconds = lifetime })
    else Ok ()

(* Generations are immutable directories; activation is a symlink swap, so a
   reader either sees the whole previous generation or the whole new one. *)
let generation_path ~root number = Filename.concat root (Printf.sprintf "generation-%d" number)
let current_path ~root = Filename.concat root "current"

let next_number = function None -> 1 | Some generation -> generation.number + 1

type audit = {
  provider : provider;
  generation_number : int;
  expires_at : float;
  outcome : string;
}

(* Records the provider, generation and outcome only. The credential value is
   never written to a log or an audit record. *)
let audit_line audit =
  Printf.sprintf "provider=%s generation=%d expires_at=%.0f outcome=%s"
    (provider_to_string audit.provider) audit.generation_number audit.expires_at
    audit.outcome
