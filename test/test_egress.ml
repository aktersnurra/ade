open Ade

let target host port = { Egress.host; port }

let patterns values =
  List.map
    (fun value ->
      match Egress.parse_pattern value with
      | Ok pattern -> pattern
      | Error reason -> Alcotest.failf "pattern %s: %s" value reason)
    values

let allows label expected values (host, port) =
  Alcotest.(check bool) label expected (Egress.allowed (patterns values) (target host port))

let host_patterns () =
  allows "exact on 443" true [ "github.com" ] ("github.com", 443);
  allows "exact on 80" true [ "github.com" ] ("github.com", 80);
  allows "exact, other port" false [ "github.com" ] ("github.com", 22);
  allows "explicit port" true [ "github.com:22" ] ("github.com", 22);
  allows "explicit port only" false [ "github.com:22" ] ("github.com", 443);
  allows "not a subdomain" false [ "github.com" ] ("api.github.com", 443);
  allows "not a suffix trick" false [ "github.com" ] ("evilgithub.com", 443);
  allows "wildcard below" true [ "*.github.com" ] ("api.github.com", 443);
  allows "wildcard deep" true [ "*.github.com" ] ("a.b.github.com", 443);
  allows "wildcard not apex" false [ "*.github.com" ] ("github.com", 443);
  allows "wildcard not suffix trick" false [ "*.github.com" ] ("evilgithub.com", 443);
  allows "case" true [ "GitHub.com" ] ("github.com", 443)

let rejected_patterns () =
  List.iter
    (fun value ->
      match Egress.parse_pattern value with
      | Ok _ -> Alcotest.failf "accepted %S" value
      | Error _ -> ())
    [ ""; "has space.com"; "a..b"; "-a.com"; "github.com:0"; "github.com:99999"; "*"; "x/y"; "a\027b" ]

let parses_connect () =
  match Egress.parse_request "CONNECT GitHub.com.:443 HTTP/1.1\r\nHost: x\r\n\r\n" with
  | Ok (Egress.Connect t) ->
      Alcotest.(check string) "host" "github.com" t.host;
      Alcotest.(check int) "port" 443 t.port
  | _ -> Alcotest.fail "expected CONNECT"

(* One checked request per connection: keep-alive and proxy credentials are
   stripped, and the origin is asked to close. *)
let rewrites_plain_http () =
  match
    Egress.parse_request
      "GET http://example.com:8080/a/b?c HTTP/1.1\r\nHost: example.com:8080\r\n\
       Proxy-Connection: keep-alive\r\nConnection: keep-alive\r\nProxy-Authorization: x\r\n\
       Accept: */*\r\n\r\n"
  with
  | Ok (Egress.Forward { target = t; head }) ->
      Alcotest.(check string) "host" "example.com" t.host;
      Alcotest.(check int) "port" 8080 t.port;
      Alcotest.(check string) "head"
        "GET /a/b?c HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        head
  | _ -> Alcotest.fail "expected a forwarded request"

let refuses_other_requests () =
  List.iter
    (fun head ->
      match Egress.parse_request head with
      | Ok _ -> Alcotest.failf "accepted %S" head
      | Error _ -> ())
    [ "GET / HTTP/1.1\r\n\r\n"; "CONNECT [::1]:443 HTTP/1.1\r\n\r\n";
      "CONNECT bad_host:443 HTTP/1.1\r\n\r\n"; "GET https://x.com/ HTTP/1.1\r\n\r\n" ]

let blocked_response_explains () =
  let response = Egress.blocked_response ~workbench:"work" (target "example.com" 443) in
  Alcotest.(check bool) "403" true (String.starts_with ~prefix:"HTTP/1.1 403" response);
  let contains needle =
    let n = String.length needle and h = String.length response in
    let rec scan i = i + n <= h && (String.sub response i n = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "tells the command" true (contains "ade net allow work example.com")

let blocked_approval_allows_the_requested_port () =
  List.iter
    (fun port ->
      let requested = target "example.com" port in
      let response = Egress.blocked_response ~workbench:"work" requested in
      let prefix = "  ade net allow work " in
      let command = List.find (String.starts_with ~prefix) (String.split_on_char '\n' response) in
      let argument = String.sub command (String.length prefix) (String.length command - String.length prefix) in
      Alcotest.(check bool) "suggested approval matches the blocked target" true
        (Egress.allowed (patterns [ argument ]) requested);
      if port <> 80 && port <> 443 then
        Alcotest.(check bool) "non-web approval does not grant web ports" false
          (Egress.allowed (patterns [ argument ]) (target "example.com" 443)))
    [ 80; 443; 22; 8443; 65535 ]

let unusual_shapes () =
  let shaped host = Egress.unusual_shape (target host 443) <> None in
  List.iter (fun h -> Alcotest.(check bool) h true (shaped h))
    [ "1.1.1.1"; "xn--ggle-0nda.com"; String.make 41 'a' ^ ".example.com"; "a.b.c.d.e.f.g.com" ];
  List.iter (fun h -> Alcotest.(check bool) h false (shaped h))
    [ "registry.npmjs.org"; "objects.githubusercontent.com"; "1password.com"; "a.b.c.d.e.com" ]

let blocked_response_gives_the_reason () =
  let response =
    Egress.blocked_response ~reason:"the classifier denied it\027[2J" ~workbench:"work"
      (target "x.com" 443)
  in
  let contains needle =
    let n = String.length needle and h = String.length response in
    let rec scan i = i + n <= h && (String.sub response i n = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "reason" true (contains "the classifier denied it");
  Alcotest.(check bool) "no escape" false (String.contains response '\027')

let sanitize_strips_control () =
  Alcotest.(check string) "escapes" "a [2J b" (Egress.sanitize "a\027[2J\nb");
  Alcotest.(check string) "cap" "abc..." (Egress.sanitize ~limit:3 "abcdef")

let log_round_trips () =
  let events =
    [ Egress.Decision { time = 1.0; target = target "a.com" 443; allowed = false };
      Egress.Classified { time = 2.0; host = "a.com"; verdict = Egress.Allow; reason = "fine" } ]
  in
  let text = String.concat "" (List.map Egress.event_to_line events) ^ "{\"torn" in
  Alcotest.(check int) "both back, torn line skipped" 2 (List.length (Egress.events_of_text text))

let log_rejects_forged_hosts () =
  let line =
    {|{"time":1,"kind":"decision","host":"a\u001b[2J.com","port":443,"allowed":false}|}
  in
  Alcotest.(check int) "skipped" 0 (List.length (Egress.events_of_text line))

let pending_tracks_refusals () =
  let d time host allowed = Egress.Decision { time; target = target host 443; allowed } in
  let events =
    [ d 1.0 "a.com" false; d 2.0 "b.com" false; d 3.0 "a.com" false; d 4.0 "c.com" true;
      Egress.Classified { time = 5.0; host = "a.com"; verdict = Egress.Deny; reason = "odd" } ]
  in
  let allowed (t : Egress.target) = t.host = "b.com" in
  match Egress.pending ~allowed events with
  | [ entry ] ->
      Alcotest.(check string) "host" "a.com" entry.target.host;
      Alcotest.(check int) "attempts" 2 entry.attempts;
      Alcotest.(check bool) "verdict" true (entry.verdict = Some (Egress.Deny, "odd"))
  | entries -> Alcotest.failf "expected one pending entry, got %d" (List.length entries)

let classifier_config =
  { Egress_classifier.model = "typesafe/jev-1.14"; api_key = Secret.file ~path:"/nonexistent" }

let classifier_body_carries_no_key () =
  let body =
    Egress_classifier.request_body classifier_config ~workbench:"work"
      ~target:(target "registry.yarnpkg.com" 443) ~allowed:[ "github.com" ] ~recent:[ "a.com" ]
  in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "model" "typesafe/jev-1.14" (to_string (member "model" json));
  let user = member "messages" json |> index 1 |> member "content" |> to_string in
  let facts = Yojson.Safe.from_string user in
  Alcotest.(check string) "requested" "registry.yarnpkg.com:443" (to_string (member "requested" facts))

let reply content =
  Yojson.Safe.to_string
    (`Assoc [ ("choices", `List [ `Assoc [ ("message", `Assoc [ ("content", `String content) ]) ] ]) ])

let classifier_parses_answers () =
  let verdict body = fst (Egress_classifier.parse_response body) in
  Alcotest.(check bool) "allow" true
    (verdict (reply {|{"verdict":"allow","reason":"Yarn registry"}|}) = Egress.Allow);
  Alcotest.(check bool) "ask" true (verdict (reply {|{"verdict":"ask","reason":"?"}|}) = Egress.Ask);
  Alcotest.(check bool) "fenced deny" true
    (verdict (reply "```json\n{\"verdict\":\"deny\",\"reason\":\"x\"}\n```") = Egress.Deny);
  Alcotest.(check bool) "unknown verdict" true
    (verdict (reply {|{"verdict":"yes"}|}) = Egress.Unavailable);
  Alcotest.(check bool) "prose" true (verdict (reply "sure, looks fine") = Egress.Unavailable);
  Alcotest.(check bool) "error" true
    (verdict {|{"error":{"message":"no such model"}}|} = Egress.Unavailable);
  Alcotest.(check string) "reason sanitized" "a [31m b"
    (snd (Egress_classifier.parse_response (reply "{\"verdict\":\"allow\",\"reason\":\"a\u{1b}[31m b\"}")))

let classifier_failures_are_unavailable () =
  let config = { classifier_config with api_key = Secret.file ~path:"/dev/null" } in
  let classify post =
    fst
      (Egress_classifier.classify ~post config ~workbench:"work" ~target:(target "a.com" 443)
         ~allowed:[] ~recent:[])
  in
  Alcotest.(check bool) "transport" true (classify (fun ~url:_ ~bearer:_ ~body:_ -> Error "down") = Egress.Unavailable);
  Alcotest.(check bool) "status" true
    (classify (fun ~url:_ ~bearer:_ ~body:_ -> Ok (500, "")) = Egress.Unavailable);
  Alcotest.(check bool) "ok" true
    (classify (fun ~url:_ ~bearer:_ ~body:_ -> Ok (200, reply {|{"verdict":"allow","reason":"r"}|}))
     = Egress.Allow)

let () =
  Alcotest.run "egress"
    [ ( "patterns",
        [ Alcotest.test_case "matching" `Quick host_patterns;
          Alcotest.test_case "rejected" `Quick rejected_patterns ] );
      ( "requests",
        [ Alcotest.test_case "connect" `Quick parses_connect;
          Alcotest.test_case "plain http" `Quick rewrites_plain_http;
          Alcotest.test_case "others" `Quick refuses_other_requests;
          Alcotest.test_case "blocked response" `Quick blocked_response_explains;
          Alcotest.test_case "approval port" `Quick blocked_approval_allows_the_requested_port;
          Alcotest.test_case "blocked reason" `Quick blocked_response_gives_the_reason;
          Alcotest.test_case "unusual shapes" `Quick unusual_shapes;
          Alcotest.test_case "sanitize" `Quick sanitize_strips_control ] );
      ( "log",
        [ Alcotest.test_case "round trip" `Quick log_round_trips;
          Alcotest.test_case "forged host" `Quick log_rejects_forged_hosts;
          Alcotest.test_case "pending" `Quick pending_tracks_refusals ] );
      ( "classifier",
        [ Alcotest.test_case "body" `Quick classifier_body_carries_no_key;
          Alcotest.test_case "answers" `Quick classifier_parses_answers;
          Alcotest.test_case "failures" `Quick classifier_failures_are_unavailable ] ) ]
