(** Credential providers.

    ADE mints short-lived credentials where a provider genuinely supports it,
    and says so plainly where it does not. A provider that cannot rotate is
    modelled as such rather than pretended into the same shape. *)

type rotation =
  | Mints_short_lived
      (** ADE can mint a fresh, expiring credential on demand. *)
  | Manually_managed of { reason : string }
      (** The credential is installed and its expiry reported, but ADE cannot
          create a new one. *)
  | Not_ade_managed of { reason : string }
      (** ADE does not handle this credential at all. *)

val rotation_of : Credential.provider -> rotation
val describe_rotation : rotation -> string

type mint_request = {
  provider : Credential.provider;
  lifetime_seconds : float;
  scope : string list;  (** repositories, audiences or similar; never a secret *)
}

type minted = { value : string; expires_at : float }

type source =
  mint_request -> now:float -> (minted, Ade_error.t) result
(** How a credential is obtained. Kept abstract so provider integrations are
    substitutable and testable without contacting a real provider. *)

val github_request :
  repositories:string list -> lifetime_seconds:float -> mint_request
(** A GitHub App installation token scoped to the declared repositories. *)

val kubernetes_request :
  audience:string -> namespace:string -> lifetime_seconds:float -> mint_request
(** A TokenRequest-backed service account token. *)

val validate_scope : mint_request -> (unit, Ade_error.t) result
(** A credential with no declared scope would carry whatever authority the
    provider defaults to, which is never what a workbench should hold. *)
