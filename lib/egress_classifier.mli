(** Advice on a refused destination, from a model behind OpenRouter.

    The classifier only annotates what the user sees in [ade net pending]; it
    never allows anything. The host name it judges was chosen by the agent, so
    a manipulated answer can at worst mislabel a request the user still has to
    approve on the host. Its output is sanitized before it is stored or shown.

    It runs on the host, with a key that never enters the guest, and sends
    OpenRouter the requested host and the workbench's allowlist. *)

type config = { model : string; api_key : Secret.t }

val endpoint : string

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
