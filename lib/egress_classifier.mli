(** A decision model behind OpenRouter's Decisions API that decides destinations
    no pattern allows.

    [Allow] lets the request through and allows the exact host and port for the
    rest of the session, when the model is at least
    {!minimum_allow_confidence} sure of it; [Ask] and [Unavailable] refuse it until the user
    allows it on the host; [Deny] refuses it with the model's reason. Names of
    an {!Egress.unusual_shape} never reach the model.

    The host name it judges was chosen by the agent, so the instructions treat
    it as data, and its reason is sanitized before it is stored or shown. It
    runs on the host, with a key that never enters the guest, and sends
    OpenRouter the requested host and the workbench's allowlist. *)

type config = { model : string; api_key : Secret.t }

val endpoint : string

val timeout_seconds : int

val minimum_allow_confidence : float
(** An allow below this confidence, or without one, is [Ask]. *)

val request_body :
  config ->
  workbench:string ->
  target:Egress.target ->
  allowed:string list ->
  recent:string list ->
  string
(** Exposed for tests: the JSON sent to OpenRouter. It carries no secret. *)

val parse_response : string -> Egress.verdict * string
(** Any malformed or failed answer is [Unavailable] with a reason. *)

type post = url:string -> bearer:string -> body:string -> (int * string, string) result

val classify :
  ?post:post ->
  config ->
  workbench:string ->
  target:Egress.target ->
  allowed:string list ->
  recent:string list ->
  Egress.verdict * string
