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
  private_key : Secret.t;
      (** A reference to the App's private key, never the key itself. It stays
          on the host: only the derived, expiring installation token reaches the
          guest. *)
  repositories : string list;
  permissions : (string * string) list;  (** e.g. [("contents", "write")] *)
}

type error =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string
  | Signing_failed of string

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

val base64url : string -> string
(** JWT uses base64url without padding, not standard base64. *)

val signing_input : config -> now:float -> string
(** The header and payload, joined and encoded. This is the exact byte string
    that gets signed; the signature is appended to it to form the JWT. *)

type signer = string -> (string, string) result
(** Sign the input with the App's RSA key, returning raw signature bytes.
    Abstract so the flow is testable without a real key. *)

val openssl_signer :
  runner:Process_runner.t -> openssl:string -> reader:Secret.reader -> config -> signer
(** Sign via openssl at the existing process boundary. ADE has no RSA
    implementation of its own, and this avoids adding a crypto dependency for
    one operation. The key is read by openssl from its path; it is never passed
    as an argument and never enters a log. *)

val sign_jwt : signer:signer -> config -> now:float -> (string, error) result

val jwt_claims : config -> now:float -> string
(** The JWT payload, exposed for tests. GitHub requires iat/exp within ten
    minutes and iss set to the App ID. *)
