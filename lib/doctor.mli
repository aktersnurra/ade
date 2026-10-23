(** Host prerequisites, checked before the first workbench is created.

    Every check is read-only. A failure names what to install or fix, because
    the alternative is a SmolVM error halfway through [ade create]. *)

type verdict = Pass | Fail | Optional_missing

type check = { name : string; verdict : verdict; detail : string }

val run :
  runner:Process_runner.t ->
  find_executable:(string -> string option) ->
  smolvm:string ->
  kvm_usable:(unit -> bool) ->
  check list
(** [smolvm] is the executable ADE will use. [kvm_usable] is only consulted on
    Linux; macOS needs no KVM. *)

val secret_checks :
  read:(Secret.t -> (unit, Ade_error.t) result) ->
  (string * (Secret.t, string) result) list ->
  check list
(** One check per [(label, reference)] of a declaration: the reference must
    parse and [read] must succeed. The value is never kept or shown, only the
    reference's {!Secret.describe}. *)

val healthy : check list -> bool
(** No required check failed; missing optional tools do not count. *)

val render : check -> string
