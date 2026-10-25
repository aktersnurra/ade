(** Secret locators, resolved only at effect boundaries.

    A [t] holds a source rather than loaded bytes. [with_value] scopes ordinary
    use, but its callback receives an OCaml string: it can retain, print or
    return those bytes inside an error. Preventing such leaks is the caller's
    responsibility, checked by transport and diagnostic tests, not this type. *)

type t

type source =
  | Keychain of { item : string }
      (** A macOS Keychain generic password, read via the [security] tool. *)
  | File of { path : string }
      (** A protected host path. The file is read at use time, never cached. *)
  | Pass of { entry : string }
      (** A [pass] (password-store) entry, read via [pass show]. The whole
          entry is the secret, so a multi-line SSH key or PEM survives intact. *)

val keychain : item:string -> t
val file : path:string -> t
val pass : entry:string -> t

val of_reference : string -> (t, string) result
(** Parse a declaration's reference, e.g. ["keychain:ade-work-ssh"],
    ["pass:ade/work-ssh"] or ["file:~/.config/ade/key.pem"]. A bare path is treated as a file, so
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

    [f] returns [unit] on success to encourage immediate use, such as writing
    to a process's stdin. It can still retain the string through effects.

    The value is not zeroed after use. This is a usage convention, not a
    non-escape or information-flow guarantee. *)
