(** The egress proxy: one HTTP proxy per proxied workbench, on the host.

    It accepts CONNECT (for HTTPS and anything else tunnelled) and absolute
    [http://] requests, one destination per connection. An allowed destination
    is resolved by the proxy itself, so the guest cannot choose the address a
    name stands for, and is refused if it resolves to loopback or link-local.
    Anything else is put to [decide], and a refusal gets
    {!Egress.blocked_response} with its reason. The proxy does not terminate
    TLS: it sees names, not content. *)

type decision = Pass | Refuse of string option  (** the reason the agent is told *)

type config = {
  workbench : string;
  is_allowed : Egress.target -> bool;  (** live policy, including revocations *)
  decide : Egress.target -> decision;
      (** for a destination no pattern allows; it may take a while, holding
          only that client's connection *)
  record : Egress.event -> unit;
  resolve : Egress.target -> (Unix.sockaddr list, string) result;
}

val default_resolve : Egress.target -> (Unix.sockaddr list, string) result
val is_local : Unix.sockaddr -> bool

val handle : config -> Unix.file_descr -> unit
(** Serve one client connection to completion and close it. *)

val listen : string -> (Unix.file_descr, string) result
(** A listening socket on [IPV4:PORT]. *)

val serve : config -> Unix.file_descr -> 'a
(** Accept forever, one thread per connection. *)
