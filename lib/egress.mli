(** The egress proxy's policy and wire format, without any sockets.

    A proxied workbench reaches the network only through ADE's proxy on the
    host. Each request names one destination, which is allowed when it matches
    the workbench's patterns and refused with an explanation otherwise. Refusals
    are recorded so the user can approve them on the host; nothing inside the
    guest can approve anything. *)

type target = { host : string; port : int }

val render_target : target -> string

val valid_host : string -> bool
(** Lowercase DNS syntax only: letters, digits, dots and hyphens. *)

val parse_target : default_port:int -> string -> (target, string) result
(** ["host"] or ["host:port"], lowercased, with a trailing dot dropped. *)

type pattern

val parse_pattern : string -> (pattern, string) result
(** ["host"] allows ports 443 and 80, ["host:port"] only that port, and
    ["*.suffix"] any name strictly below the suffix. *)

val allowed : pattern list -> target -> bool

type request =
  | Connect of target
  | Forward of { target : target; head : string }
      (** A plain-HTTP request; [head] is rewritten to origin form, without
          hop-by-hop headers and with [Connection: close], so one connection
          carries one checked request. *)

val header_end : string -> int option
(** The offset just past the blank line ending a request head, if present. *)

val parse_request : string -> (request, string) result

val blocked_response : workbench:string -> target -> string
(** A complete 403 response telling the agent how the user can allow it. *)

val sanitize : ?limit:int -> string -> string
(** Printable ASCII only, trimmed and capped, for anything shown on the host. *)

type verdict = Routine | Suspicious | Unavailable

val verdict_to_string : verdict -> string

type event =
  | Decision of { time : float; target : target; allowed : bool }
  | Classified of { time : float; host : string; verdict : verdict; reason : string }

val event_to_line : event -> string
val events_of_text : string -> event list
(** Unparsable lines are skipped, so a torn last line does not hide the log. *)

type pending = {
  target : target;
  attempts : int;
  last_attempt : float;
  verdict : (verdict * string) option;  (** the latest classification *)
}

val pending : allowed:(target -> bool) -> event list -> pending list
(** Refused targets that are still not allowed, most recent first. *)
