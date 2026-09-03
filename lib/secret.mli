(** Credentials that cannot be printed, and cannot be written into config.

    Two separate guarantees, both enforced by this signature rather than by
    discipline:

    - A [t] names a source; it does not hold a value. There is no constructor
      taking a credential, so a secret cannot be embedded in a declaration and
      therefore cannot be committed.
    - There is no accessor returning the value. The bytes exist only inside the
      callback given to {!with_value}, so they cannot reach argv, a log line or
      an error message. *)

type t

type source =
  | Keychain of { item : string }
      (** A macOS Keychain generic password, read via the [security] tool. *)
  | File of { path : string }
      (** A protected host path. The file is read at use time, never cached. *)

val keychain : item:string -> t
val file : path:string -> t

val of_reference : string -> (t, string) result
(** Parse a declaration's reference, e.g. ["keychain:ade-work-ssh"] or
    ["file:~/.config/ade/key.pem"]. A bare path is treated as a file, so
    existing declarations keep working.

    Deliberately the only way to build a [t] from configuration: it takes a
    locator, never a credential. *)

val source : t -> source

val describe : t -> string
(** A diagnostic string naming where the secret lives, such as
    ["keychain item ade-work-ssh"]. This is the only function returning a
    string, and it cannot return the credential because the credential has not
    been read. *)

type reader = source -> (string, Ade_error.t) result
(** How a source is resolved. Abstract so tests need no Keychain entry. *)

val default_reader : runner:Process_runner.t -> reader

val with_value :
  ?reader:reader -> t -> f:(string -> (unit, Ade_error.t) result) ->
  (unit, Ade_error.t) result
(** Resolve the secret and pass it to [f].

    [f] returns [unit] on success, not a value: were it polymorphic, a caller
    could return the credential itself and defeat the point. Anything a caller
    needs from the secret must be produced as an effect inside [f], such as
    writing it to a process's stdin.

    The value is not zeroed after use. OCaml strings are immutable, so
    scrubbing would require an unsafe mutable buffer through every reader; what
    this signature guarantees is narrower and still worth having -- the
    credential never becomes a return value, so it cannot reach a caller, a log
    line, or an error message. *)
