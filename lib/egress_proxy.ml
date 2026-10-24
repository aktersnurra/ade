type decision = Pass | Refuse of string option

type config = {
  workbench : string;
  policy : unit -> Egress.pattern list;
  decide : Egress.target -> decision;
  record : Egress.event -> unit;
  resolve : Egress.target -> (Unix.sockaddr list, string) result;
}

(* Loopback and link-local destinations are the host itself and cloud metadata
   services. An allowed name that resolves to one is refused, so allowing a
   name can never become a way to reach the host's own services, the proxy
   included. *)
let is_local = function
  | Unix.ADDR_UNIX _ -> true
  | Unix.ADDR_INET (address, _) ->
      let text = Unix.string_of_inet_addr address in
      List.exists
        (fun prefix -> String.starts_with ~prefix text)
        [ "127."; "0."; "169.254."; "::ffff:127."; "::ffff:169.254."; "fe80:" ]
      || text = "::1" || text = "::"

let default_resolve (target : Egress.target) =
  match
    Unix.getaddrinfo target.host (string_of_int target.port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  with
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | [] -> Error "the name does not resolve"
  | infos ->
      let addresses = List.map (fun info -> info.Unix.ai_addr) infos in
      if List.exists is_local addresses then Error "the name resolves to a local address"
      else Ok addresses

let send fd text =
  let rec go offset =
    if offset < String.length text then
      let written = Unix.write_substring fd text offset (String.length text - offset) in
      go (offset + written)
  in
  try go 0 with Unix.Unix_error _ -> ()

let close fd = try Unix.close fd with Unix.Unix_error _ -> ()

let plain_response status reason =
  let body = "ade: " ^ reason ^ "\n" in
  Printf.sprintf "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
    status (String.length body) body

let maximum_head = 16 * 1024

let read_head fd =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    let text = Buffer.contents buffer in
    match Egress.header_end text with
    | Some stop -> Ok (String.sub text 0 stop, String.sub text stop (String.length text - stop))
    | None when Buffer.length buffer > maximum_head -> Error "the request head is too large"
    | None -> (
        match Unix.read fd chunk 0 (Bytes.length chunk) with
        | 0 -> Error "the client closed the connection"
        | n ->
            Buffer.add_subbytes buffer chunk 0 n;
            loop ()
        | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error))
  in
  loop ()

let connect addresses =
  List.find_map
    (fun address ->
      let domain = Unix.domain_of_sockaddr address in
      let fd = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
      match Unix.connect fd address with
      | () -> Some fd
      | exception Unix.Unix_error _ ->
          close fd;
          None)
    addresses

let pump source destination =
  let buffer = Bytes.create 65536 in
  let rec loop () =
    match Unix.read source buffer 0 (Bytes.length buffer) with
    | 0 -> ()
    | n ->
        send destination (Bytes.sub_string buffer 0 n);
        loop ()
    | exception Unix.Unix_error _ -> ()
  in
  loop ();
  try Unix.shutdown destination Unix.SHUTDOWN_SEND with Unix.Unix_error _ -> ()

let splice client upstream =
  let other = Thread.create (fun () -> pump upstream client) () in
  pump client upstream;
  Thread.join other

let handle config client =
  Fun.protect ~finally:(fun () -> close client) @@ fun () ->
  (* A client that never finishes its request head must not hold a thread
     forever; once the tunnel is up, an idle connection is legitimate. *)
  (try Unix.setsockopt_float client Unix.SO_RCVTIMEO 30.0 with Unix.Unix_error _ -> ());
  match read_head client with
  | Error _ -> ()
  | Ok (head, early) -> (
      match Egress.parse_request head with
      | Error reason -> send client (plain_response "400 Bad Request" reason)
      | Ok request -> (
          let target =
            match request with Egress.Connect target | Egress.Forward { target; _ } -> target
          in
          let decision =
            if Egress.allowed (config.policy ()) target then Pass else config.decide target
          in
          config.record
            (Egress.Decision { time = Unix.gettimeofday (); target; allowed = decision = Pass });
          match decision with
          | Refuse reason ->
              send client (Egress.blocked_response ?reason ~workbench:config.workbench target)
          | Pass ->
            match config.resolve target with
            | Error reason ->
                send client
                  (plain_response "502 Bad Gateway" (Egress.render_target target ^ ": " ^ reason))
            | Ok addresses -> (
                match connect addresses with
                | None ->
                    send client
                      (plain_response "502 Bad Gateway"
                         (Egress.render_target target ^ ": connection failed"))
                | Some upstream ->
                    Fun.protect ~finally:(fun () -> close upstream) @@ fun () ->
                    (try Unix.setsockopt_float client Unix.SO_RCVTIMEO 0.0
                     with Unix.Unix_error _ -> ());
                    (match request with
                     | Egress.Connect _ -> send client "HTTP/1.1 200 Connection Established\r\n\r\n"
                     | Egress.Forward { head; _ } -> send upstream head);
                    if early <> "" then send upstream early;
                    splice client upstream)))

let listen address =
  match Unix.inet_addr_of_string (String.sub address 0 (String.rindex address ':')) with
  | exception (Failure _ | Not_found) -> Error ("not an address: " ^ address)
  | inet -> (
      let port = int_of_string (String.sub address (String.rindex address ':' + 1)
                                  (String.length address - String.rindex address ':' - 1)) in
      let fd = Unix.socket ~cloexec:true (Unix.domain_of_sockaddr (Unix.ADDR_INET (inet, port)))
          Unix.SOCK_STREAM 0 in
      try
        Unix.setsockopt fd Unix.SO_REUSEADDR true;
        Unix.bind fd (Unix.ADDR_INET (inet, port));
        Unix.listen fd 64;
        Ok fd
      with Unix.Unix_error (error, _, _) ->
        close fd;
        Error (Printf.sprintf "cannot listen on %s: %s" address (Unix.error_message error)))

let serve config socket =
  (* A client that disappears mid-write must cost one thread, not the proxy. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let rec loop () =
    match Unix.accept ~cloexec:true socket with
    | client, _ ->
        ignore (Thread.create (fun () -> try handle config client with _ -> close client) ());
        loop ()
    | exception Unix.Unix_error ((Unix.EINTR | Unix.ECONNABORTED), _, _) -> loop ()
  in
  loop ()
