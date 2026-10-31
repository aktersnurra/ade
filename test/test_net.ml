open Ade

let temp_root () =
  let path = Filename.temp_file "ade-net-" "" in
  Sys.remove path;
  path

let name =
  match Workbench_name.of_string "work" with Ok name -> name | Error _ -> assert false

let target host = { Egress.host; port = 443 }

(* A decider over a scripted classifier, counting how often it is asked. *)
let setup ?(answer = fun _ -> (Egress.Allow, "a package registry")) ?(classifier = true)
    ?(notify = fun _ -> ()) () =
  let paths = State_paths.make ~root:(temp_root ()) () in
  let calls = ref 0 and events = ref [] in
  let classify ~target ~allowed:_ ~recent:_ =
    incr calls;
    answer target
  in
  let decide =
    Net.decider ~paths ~name
      ~record:(fun event -> events := event :: !events)
      ~allowed:(fun () -> [ "github.com" ])
      ~classify:(if classifier then Some classify else None)
      ~notify
  in
  (paths, decide, calls, events)

let read path = try In_channel.with_open_bin path In_channel.input_all with Sys_error _ -> ""

let passes = function Egress_proxy.Pass -> true | Egress_proxy.Refuse _ -> false

let allow_passes_and_is_remembered () =
  let paths, decide, calls, events = setup () in
  Alcotest.(check bool) "passes" true (passes (decide (target "registry.yarnpkg.com")));
  Alcotest.(check bool) "again" true (passes (decide (target "registry.yarnpkg.com")));
  Alcotest.(check int) "asked once" 1 !calls;
  Alcotest.(check string) "exact host and port" "registry.yarnpkg.com:443\n"
    (read (State_paths.auto_allow_file paths name));
  Alcotest.(check bool) "logged" true
    (List.exists (function Egress.Classified { verdict = Egress.Allow; _ } -> true | _ -> false) !events)

let deny_and_ask_refuse () =
  let _, decide, calls, _ =
    setup
      ~answer:(fun (t : Egress.target) ->
        if t.host = "bad.example" then (Egress.Deny, "a request-capture service")
        else (Egress.Ask, "not recognised"))
      ()
  in
  (match decide (target "bad.example") with
   | Egress_proxy.Refuse (Some reason) ->
       Alcotest.(check bool) "says denied" true (String.starts_with ~prefix:"the classifier denied" reason)
   | _ -> Alcotest.fail "expected a refusal with a reason");
  Alcotest.(check bool) "ask refuses" false (passes (decide (target "unknown.example")));
  Alcotest.(check bool) "ask again, not re-asked" false (passes (decide (target "unknown.example")));
  Alcotest.(check int) "two questions" 2 !calls

(* Names shaped like data go to the user whatever the model would say. *)
let unusual_names_never_reach_the_model () =
  let _, decide, calls, _ = setup () in
  Alcotest.(check bool) "raw ip" false (passes (decide (target "1.2.3.4")));
  Alcotest.(check bool) "long label" false
    (passes (decide (target (String.make 50 'a' ^ ".attacker.example"))));
  Alcotest.(check int) "model not asked" 0 !calls

let without_a_classifier_everything_asks () =
  let _, decide, _, _ = setup ~classifier:false () in
  match decide (target "registry.yarnpkg.com") with
  | Egress_proxy.Refuse None -> ()
  | _ -> Alcotest.fail "expected a plain refusal"

(* The user hears about a host that needs them once per run, and never about
   one the classifier settled. *)
let hosts_that_need_the_user_notify_once () =
  let notified = ref [] in
  let notify (t : Egress.target) = notified := t.host :: !notified in
  let _, decide, _, _ =
    setup ~notify
      ~answer:(fun (t : Egress.target) ->
        match t.host with
        | "bad.example" -> (Egress.Deny, "a request-capture service")
        | "registry.yarnpkg.com" -> (Egress.Allow, "a package registry")
        | "down.example" -> (Egress.Unavailable, "classifier unreachable")
        | _ -> (Egress.Ask, "not recognised"))
      ()
  in
  List.iter (fun host -> ignore (decide (target host)))
    [ "unknown.example"; "unknown.example"; "bad.example"; "registry.yarnpkg.com";
      "down.example"; "1.2.3.4" ];
  Alcotest.(check (list string)) "notified" [ "unknown.example"; "down.example"; "1.2.3.4" ]
    (List.rev !notified);
  let notified = ref 0 in
  let _, decide, _, _ = setup ~classifier:false ~notify:(fun _ -> incr notified) () in
  ignore (decide (target "registry.yarnpkg.com"));
  Alcotest.(check int) "without a classifier too" 1 !notified

let declaration () =
  let path = Filename.temp_file "ade-net-" ".toml" in
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel
        {|name = "work"
image = "docker.io/menci/archlinuxarm:base-devel"

[resources]
cpus = 2
memory_mib = 2048
overlay_gib = 8
workspace_gib = 16

[network]
posture = "proxied"
proxy = "127.0.0.1:3128"
hosts = ["github.com"]
|});
  match Declaration.load path with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

let revoke_takes_back_an_auto_allow () =
  let paths, decide, calls, _ = setup () in
  let declaration = declaration () in
  ignore (decide (target "registry.yarnpkg.com"));
  (match Net.revoke ~paths declaration ~host:"registry.yarnpkg.com" with
   | Ok still_declared -> Alcotest.(check bool) "not declared" false still_declared
   | Error error -> Alcotest.failf "revoke: %s" (Ade_error.to_string error));
  Alcotest.(check bool) "gone from the allowed hosts" false
    (List.mem "registry.yarnpkg.com:443" (Net.allowed_hosts ~paths declaration));
  Alcotest.(check bool) "refused now" false (passes (decide (target "registry.yarnpkg.com")));
  Alcotest.(check int) "model not asked again" 1 !calls;
  (match Net.allow ~paths declaration ~host:"registry.yarnpkg.com" ~scope:Net.Session with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "allow: %s" (Ade_error.to_string error));
  Alcotest.(check bool) "allowing again lifts it" true
    (List.mem "registry.yarnpkg.com" (Net.allowed_hosts ~paths declaration));
  match Net.revoke ~paths declaration ~host:"github.com" with
  | Ok still_declared -> Alcotest.(check bool) "declared hosts stay" true still_declared
  | Error error -> Alcotest.failf "revoke: %s" (Ade_error.to_string error)

(* Two requests for one new host ask the model once; the second waits. *)
let concurrent_requests_ask_once () =
  let _, decide, calls, _ =
    setup
      ~answer:(fun _ ->
        Thread.delay 0.2;
        (Egress.Allow, "slow"))
      ()
  in
  let results = Array.make 2 false in
  let threads =
    List.init 2 (fun i -> Thread.create (fun () -> results.(i) <- passes (decide (target "slow.example"))) ())
  in
  List.iter Thread.join threads;
  Alcotest.(check int) "asked once" 1 !calls;
  Alcotest.(check bool) "both pass" true (results.(0) && results.(1))

let () =
  Alcotest.run "net"
    [ ( "decider",
        [ Alcotest.test_case "allow" `Quick allow_passes_and_is_remembered;
          Alcotest.test_case "deny and ask" `Quick deny_and_ask_refuse;
          Alcotest.test_case "unusual names" `Quick unusual_names_never_reach_the_model;
          Alcotest.test_case "no classifier" `Quick without_a_classifier_everything_asks;
          Alcotest.test_case "notify" `Quick hosts_that_need_the_user_notify_once;
          Alcotest.test_case "revoke" `Quick revoke_takes_back_an_auto_allow;
          Alcotest.test_case "concurrent" `Quick concurrent_requests_ask_once ] ) ]
