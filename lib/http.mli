(** The HTTP boundary, implemented by shelling out to curl.

    ADE has no HTTP client and adding one for a single token exchange would be
    a large dependency for a small need. curl is on every macOS host, and going
    through {!Process_runner} keeps network calls on the same auditable
    boundary as everything else ADE runs. *)

val post :
  ?runner:Process_runner.t ->
  ?curl:string ->
  url:string ->
  bearer:string ->
  body:string ->
  unit ->
  (int * string, string) result
(** POST a JSON [body] with a bearer token, returning the status and body.

    The token is written to curl's stdin as a header rather than passed as an
    argument: anything in argv is readable from the process table by any local
    process. A transport failure is an [Error]; an HTTP error status is a
    successful call returning that status, because the caller distinguishes
    them differently. *)
