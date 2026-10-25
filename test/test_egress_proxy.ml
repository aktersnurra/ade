open Ade

(* A real proxy on loopback, in front of a real upstream on loopback. Name
   resolution is injected, so "allowed.test" reaches the upstream without DNS
   and without tripping the loopback refusal, which has its own test. *)

let port_of fd =
  match Unix.getsockname fd with Unix.ADDR_INET (_, port) -> port | _ -> assert false

let read_all fd =
  let buffer = Buffer.create 256 in
  let chunk = Bytes.create 1024 in
  let rec loop () =
    match Unix.read fd chunk 0 1024 with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buffer chunk 0 n;
        loop ()
    | exception Unix.Unix_error _ -> ()
  in
  loop ();
  Buffer.contents buffer

(* Echoes what it receives, prefixed, then closes: enough to see bytes cross
   the tunnel in both directions. *)
let upstream () =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt fd Unix.SO_REUSEADDR true;
  Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen fd 8;
  let received = ref [] in
  let lock = Mutex.create () in
  let rec serve () =
    let client, _ = Unix.accept fd in
    let chunk = Bytes.create 4096 in
    let n = Unix.read client chunk 0 4096 in
    let data = Bytes.sub_string chunk 0 n in
    Mutex.protect lock (fun () -> received := data :: !received);
    ignore (Unix.write_substring client ("echo:" ^ data) 0 (5 + n));
    Unix.close client;
    serve ()
  in
  ignore (Thread.create serve ());
  (port_of fd, fun () -> Mutex.protect lock (fun () -> !received))

let proxy ~upstream_port =
  let events = ref [] and refusals = ref [] in
  let lock = Mutex.create () in
  let patterns =
    List.filter_map (fun p -> Result.to_option (Egress.parse_pattern p)) [ "allowed.test" ]
  in
  let config =
    {
      Egress_proxy.workbench = "work";
      is_allowed = Egress.allowed patterns;
      record = (fun event -> Mutex.protect lock (fun () -> events := event :: !events));
      decide =
        (fun target ->
          Mutex.protect lock (fun () -> refusals := target :: !refusals);
          if target.Egress.host = "auto.test" then Egress_proxy.Pass
          else Egress_proxy.Refuse (Some "the classifier denied it"));
      resolve =
        (fun _ -> Ok [ Unix.ADDR_INET (Unix.inet_addr_loopback, upstream_port) ]);
    }
  in
  let socket =
    match Egress_proxy.listen "127.0.0.1:0" with
    | Ok socket -> socket
    | Error reason -> Alcotest.failf "listen: %s" reason
  in
  ignore (Thread.create (fun () -> Egress_proxy.serve config socket) ());
  ( port_of socket,
    (fun () -> Mutex.protect lock (fun () -> !events)),
    fun () -> Mutex.protect lock (fun () -> !refusals) )

let exchange port request =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  ignore (Unix.write_substring fd request 0 (String.length request));
  Unix.shutdown fd Unix.SHUTDOWN_SEND;
  let response = read_all fd in
  Unix.close fd;
  response

let starts_with prefix text = String.starts_with ~prefix text

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let tunnels_an_allowed_connect () =
  let upstream_port, _ = upstream () in
  let port, events, _ = proxy ~upstream_port in
  let response = exchange port "CONNECT allowed.test:443 HTTP/1.1\r\nHost: allowed.test\r\n\r\nhello" in
  Alcotest.(check bool) "established" true (starts_with "HTTP/1.1 200" response);
  Alcotest.(check bool) "tunnelled both ways" true (contains "echo:hello" response);
  Alcotest.(check bool) "logged as allowed" true
    (List.exists
       (function Egress.Decision { allowed = true; target; _ } -> target.host = "allowed.test" | _ -> false)
       (events ()))

let refuses_and_reports_others () =
  let upstream_port, received = upstream () in
  let port, events, refusals = proxy ~upstream_port in
  let response = exchange port "CONNECT other.test:443 HTTP/1.1\r\n\r\nsecret" in
  Alcotest.(check bool) "403" true (starts_with "HTTP/1.1 403" response);
  Alcotest.(check bool) "explains" true (contains "ade net allow work other.test" response);
  Alcotest.(check bool) "nothing reached upstream" true (received () = []);
  Alcotest.(check bool) "reported" true
    (List.exists (fun (t : Egress.target) -> t.host = "other.test") (refusals ()));
  Alcotest.(check bool) "logged as refused" true
    (List.exists (function Egress.Decision { allowed = false; _ } -> true | _ -> false) (events ()))

(* What decide passes goes through as if a pattern had allowed it. *)
let a_decided_pass_tunnels () =
  let upstream_port, _ = upstream () in
  let port, _, _ = proxy ~upstream_port in
  let response = exchange port "CONNECT auto.test:443 HTTP/1.1\r\n\r\nhi" in
  Alcotest.(check bool) "established" true (starts_with "HTTP/1.1 200" response);
  Alcotest.(check bool) "tunnelled" true (contains "echo:hi" response)

let a_refusal_carries_its_reason () =
  let upstream_port, _ = upstream () in
  let port, _, _ = proxy ~upstream_port in
  let response = exchange port "CONNECT other.test:443 HTTP/1.1\r\n\r\n" in
  Alcotest.(check bool) "reason" true (contains "the classifier denied it" response)

let forwards_plain_http_rewritten () =
  let upstream_port, received = upstream () in
  let port, _, _ = proxy ~upstream_port in
  let response =
    exchange port
      "GET http://allowed.test/path HTTP/1.1\r\nHost: allowed.test\r\nProxy-Connection: keep-alive\r\n\r\n"
  in
  Alcotest.(check bool) "upstream answered" true (starts_with "echo:GET /path HTTP/1.1" response);
  match received () with
  | [ head ] ->
      Alcotest.(check bool) "closes" true (contains "Connection: close" head);
      Alcotest.(check bool) "no proxy headers" false (contains "Proxy-Connection" head)
  | _ -> Alcotest.fail "expected exactly one upstream request"

let local_addresses_are_refused () =
  let local text = Egress_proxy.is_local (Unix.ADDR_INET (Unix.inet_addr_of_string text, 443)) in
  List.iter (fun a -> Alcotest.(check bool) a true (local a)) [ "127.0.0.1"; "127.8.9.1"; "169.254.169.254"; "::1"; "0.0.0.0" ];
  List.iter (fun a -> Alcotest.(check bool) a false (local a)) [ "140.82.112.3"; "10.0.0.1"; "2606:4700::1" ]

let () =
  Alcotest.run "egress proxy"
    [ ( "proxy",
        [ Alcotest.test_case "connect" `Quick tunnels_an_allowed_connect;
          Alcotest.test_case "refused" `Quick refuses_and_reports_others;
          Alcotest.test_case "plain http" `Quick forwards_plain_http_rewritten;
          Alcotest.test_case "decided pass" `Quick a_decided_pass_tunnels;
          Alcotest.test_case "refusal reason" `Quick a_refusal_carries_its_reason;
          Alcotest.test_case "local addresses" `Quick local_addresses_are_refused ] ) ]
