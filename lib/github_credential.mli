(** GitHub App installation tokens.

    ADE authenticates as a GitHub App, not as a user: an installation token is
    scoped to declared repositories and permissions and expires within an hour,
    which is what makes it safe to hand to a workbench.

    The flow is: sign a short-lived JWT with the App's private key, exchange it
    for an installation token, install that token into guest tmpfs. ADE never
    stores the installation token; it mints a fresh one when the current
    generation approaches expiry. *)

type config = {
  app_id : string;
  installation_id : string;
  private_key_path : string;
      (** A host path or Keychain reference. The key never enters the guest:
          only the derived, expiring installation token does. *)
  repositories : string list;
  permissions : (string * string) list;  (** e.g. [("contents", "write")] *)
}

type error =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string

val describe_error : error -> string

val load_config : Otoml.t -> (config, error) result
(** Read the [[credentials.github]] table of a workbench declaration. *)

val validate : config -> (unit, error) result
(** Refuse a configuration that would mint an over-broad credential. *)

type http_post =
  url:string -> bearer:string -> (int * string, string) result
(** The HTTP boundary, abstract so the exchange is testable without contacting
    GitHub. *)

val token_url : config -> string

val exchange :
  post:http_post -> config -> jwt:string -> now:float ->
  (Provider.minted, error) result
(** Exchange a signed App JWT for an installation token. *)

val jwt_claims : config -> now:float -> string
(** The JWT payload, exposed for tests. GitHub requires iat/exp within ten
    minutes and iss set to the App ID. *)
