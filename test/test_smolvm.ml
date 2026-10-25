open Ade

(* A fake runner records every request and replies from a scripted table, so
   adapter behavior is tested without a real runtime. *)
let fake ?(status = 0) ?(stdout = "") ?(stderr = "") recorder =
  fun request ->
    recorder := request :: !recorder;
    Ok { Process_runner.status; stdout; stderr }

let adapter runner = Smolvm.make ~executable:"/usr/bin/true" ~runner

let load_declaration () =
  match Declaration.load "../workbenches/work.toml" with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

let name_exn value =
  match Workbench_name.of_string value with
  | Ok name -> name
  | Error _ -> Alcotest.failf "bad test name %s" value

let state_case input expected () =
  match Smolvm.parse_state input with
  | Ok actual ->
      let render = function
        | Smolvm.Absent -> "absent"
        | Smolvm.Created -> "created"
        | Smolvm.Stopped -> "stopped"
        | Smolvm.Running -> "running"
      in
      Alcotest.(check string) input expected (render actual)
  | Error reason -> Alcotest.failf "%s: %s" input reason

let unknown_state_is_rejected () =
  match Smolvm.parse_state "teleporting" with
  | Ok _ -> Alcotest.fail "expected an unknown state to be rejected"
  | Error _ -> ()

let malformed_json_is_reported () =
  let recorder = ref [] in
  let smolvm = adapter (fake ~stdout:"{not json" recorder) in
  match Smolvm.state smolvm (name_exn "work") with
  | Error (Ade_error.Runtime_output_invalid _) -> ()
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)
  | Ok _ -> Alcotest.fail "expected malformed JSON to be rejected"

let missing_machine_is_absent () =
  let recorder = ref [] in
  let smolvm =
    adapter (fake ~status:1 ~stderr:"machine 'work' not found" recorder)
  in
  match Smolvm.state smolvm (name_exn "work") with
  | Ok Smolvm.Absent -> ()
  | Ok _ -> Alcotest.fail "expected an unknown machine to read as absent"
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)

let running_state_is_parsed () =
  let recorder = ref [] in
  let smolvm = adapter (fake ~stdout:{|{"name":"work","state":"running"}|} recorder) in
  match Smolvm.state smolvm (name_exn "work") with
  | Ok Smolvm.Running -> ()
  | Ok _ -> Alcotest.fail "expected running"
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)

(* The declaration is the only source of resources and network posture. *)
let create_argv_follows_the_declaration () =
  let argv = Smolvm.create_argv (load_declaration ()) ~mounts:[] in
  let rec index_of needle = function
    | [] -> None
    | value :: rest -> if value = needle then Some rest else index_of needle rest
  in
  let value_after flag =
    match index_of flag argv with Some (value :: _) -> Some value | _ -> None
  in
  Alcotest.(check (option string)) "name" (Some "work") (value_after "--name");
  Alcotest.(check (option string)) "cpus" (Some "6") (value_after "--cpus");
  Alcotest.(check (option string)) "memory" (Some "12288") (value_after "--mem");
  Alcotest.(check (option string)) "overlay" (Some "32") (value_after "--overlay");
  Alcotest.(check (option string)) "storage" (Some "256") (value_after "--storage");
  Alcotest.(check bool) "networking enabled" true (List.mem "--net" argv);
  Alcotest.(check bool) "allowlists github" true
    (List.exists (fun value -> value = "github.com") argv)

(* A sealed workbench must never be created with networking enabled. *)
let sealed_declaration_creates_no_network () =
  match Declaration.load "../workbenches/work-offline.toml" with
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  | Ok declaration ->
      let argv = Smolvm.create_argv declaration ~mounts:[] in
      Alcotest.(check bool) "no --net" false (List.mem "--net" argv);
      Alcotest.(check bool) "no allow-host" false (List.mem "--allow-host" argv);
      Alcotest.(check bool) "no allow-cidr" false (List.mem "--allow-cidr" argv)

(* A proxied machine may reach its proxy and nothing else; the hosts are the
   proxy's business and never reach the runtime. *)
let proxied_declaration_reaches_only_its_proxy () =
  match Declaration.load "../workbenches/work-proxied.toml.example" with
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  | Ok declaration ->
      let argv = Smolvm.create_argv declaration ~mounts:[] in
      Alcotest.(check bool) "--net" true (List.mem "--net" argv);
      Alcotest.(check bool) "no allow-host" false (List.mem "--allow-host" argv);
      Alcotest.(check bool) "host mediation backend" true (List.mem "virtio-net" argv);
      Alcotest.(check bool) "explicit backend" true (List.mem "--net-backend" argv);
      Alcotest.(check (list string)) "one cidr" [ "192.0.2.10/32" ]
        (let rec cidrs = function
           | "--allow-cidr" :: cidr :: rest -> cidr :: cidrs rest
           | _ :: rest -> cidrs rest
           | [] -> []
         in
         cidrs argv)

(* The runtime forwards an agent only into a machine created to accept one. *)
let dedicated_ssh_requests_agent_forwarding () =
  let argv = Smolvm.create_argv (load_declaration ()) ~mounts:[] in
  Alcotest.(check bool) "work forwards" true (List.mem "--ssh-agent" argv);
  match Declaration.load "../workbenches/work-offline.toml" with
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check bool) "disabled does not" false
        (List.mem "--ssh-agent" (Smolvm.create_argv declaration ~mounts:[]))

(* Only resolved mounts reach the runtime, one --volume each, read-only marked. *)
let create_argv_carries_resolved_mounts () =
  let mounts =
    [ { Host_mount.source = "/home/u/code/a"; guest = "/src/a"; read_only = true };
      { Host_mount.source = "/home/u/data"; guest = "/work/data"; read_only = false } ]
  in
  let argv = Smolvm.create_argv (load_declaration ()) ~mounts in
  let rec volumes = function
    | "--volume" :: spec :: rest -> spec :: volumes rest
    | _ :: rest -> volumes rest
    | [] -> []
  in
  Alcotest.(check (list string)) "volumes"
    [ "/home/u/code/a:/src/a:ro"; "/home/u/data:/work/data" ] (volumes argv)

(* Attachment must hand over the terminal; capture would break interactivity. *)
let attach_inherits_the_terminal () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  match Smolvm.attach smolvm (name_exn "work") ~command:[] with
  | Error error -> Alcotest.failf "attach: %s" (Ade_error.to_string error)
  | Ok () -> (
      match !recorder with
      | [ request ] ->
          Alcotest.(check bool) "inherits stdio" true
            (request.Process_runner.stdio = Process_runner.Inherit)
      | _ -> Alcotest.fail "expected exactly one request")

(* Ordinary exec must not take over the terminal. *)
let exec_captures_output () =
  let recorder = ref [] in
  let smolvm = adapter (fake ~stdout:"hello\n" recorder) in
  match Smolvm.exec smolvm (name_exn "work") [ "echo"; "hello" ] with
  | Error error -> Alcotest.failf "exec: %s" (Ade_error.to_string error)
  | Ok output -> (
      Alcotest.(check string) "stdout" "hello\n" output.Process_runner.stdout;
      match !recorder with
      | [ request ] ->
          Alcotest.(check bool) "captures" true
            (request.Process_runner.stdio = Process_runner.Capture);
          Alcotest.(check bool) "separates command" true
            (List.mem "--" request.Process_runner.argv)
      | _ -> Alcotest.fail "expected exactly one request")

(* The SSH agent socket is a capability and travels in the environment, never
   in argv where the process table would expose it. *)
let ssh_socket_never_reaches_argv () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  match Smolvm.start ~ssh_auth_sock:"/tmp/ade-work-agent.sock" smolvm (name_exn "work") with
  | Error error -> Alcotest.failf "start: %s" (Ade_error.to_string error)
  | Ok () -> (
      match !recorder with
      | [ request ] ->
          Alcotest.(check bool) "not in argv" false
            (List.mem "/tmp/ade-work-agent.sock" request.Process_runner.argv);
          Alcotest.(check (option string)) "in environment"
            (Some "/tmp/ade-work-agent.sock")
            (List.assoc_opt "SSH_AUTH_SOCK" request.Process_runner.env)
      | _ -> Alcotest.fail "expected exactly one request")

(* The argv of the one request an adapter call made. *)
let only_argv recorder =
  match !recorder with
  | [ request ] -> request.Process_runner.argv
  | _ -> Alcotest.fail "expected exactly one request"

let succeed label = function
  | Ok _ -> ()
  | Error error -> Alcotest.failf "%s: %s" label (Ade_error.to_string error)

(* SmolVM 1.32 discards piped stdin unless exec is given -i, and still exits
   0, so a provision script sent without it never runs and reports success. *)
let piped_stdin_keeps_stdin_open () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  succeed "exec" (Smolvm.exec_with_stdin smolvm (name_exn "work") [ "bash"; "-s" ] ~stdin:"true\n");
  Alcotest.(check (list string)) "argv"
    [ "machine"; "exec"; "-i"; "--name"; "work"; "--"; "bash"; "-s" ]
    (only_argv recorder)

(* Delete asks for confirmation unless forced, and refuses when stdin is not
   a terminal. ADE asks first itself: ade rm requires --yes. *)
let delete_is_forced () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  succeed "delete" (Smolvm.delete smolvm (name_exn "work"));
  Alcotest.(check (list string)) "argv"
    [ "machine"; "delete"; "--name"; "work"; "--force" ]
    (only_argv recorder)

(* machine shell takes no command, so a command is run with an interactive
   exec on a terminal instead. *)
let attach_without_a_command_opens_a_shell () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  succeed "attach" (Smolvm.attach smolvm (name_exn "work") ~command:[]);
  Alcotest.(check (list string)) "argv" [ "machine"; "shell"; "--name"; "work" ]
    (only_argv recorder)

let attach_with_a_command_execs_on_a_terminal () =
  let recorder = ref [] in
  let smolvm = adapter (fake recorder) in
  succeed "attach" (Smolvm.attach smolvm (name_exn "work") ~command:[ "herdr" ]);
  Alcotest.(check (list string)) "argv"
    [ "machine"; "exec"; "-i"; "-t"; "--name"; "work"; "--"; "herdr" ]
    (only_argv recorder)

let guard_token_is_only_in_the_host_start_environment () =
  let binding, socket =
    match Egress_guard.listen ~proxy:"127.0.0.1:3128" () with
    | Ok pair -> pair
    | Error reason -> Alcotest.fail reason
  in
  Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      let recorder = ref [] in
      let smolvm = adapter (fake recorder) in
      (match Smolvm.start ~egress_guard:binding smolvm (name_exn "work") with
       | Error error -> Alcotest.fail (Ade_error.to_string error)
       | Ok () -> ());
      let request = List.hd !recorder in
      Alcotest.(check bool) "mediation required" true
        (List.mem "--mediated-egress" request.Process_runner.argv);
      Alcotest.(check bool) "bound listener" true
        (List.mem (Egress_guard.address binding) request.Process_runner.argv);
      Alcotest.(check bool) "token absent from argv" false
        (List.mem (Egress_guard.token_hex binding) request.Process_runner.argv);
      Alcotest.(check (option string)) "host token"
        (Some (Egress_guard.token_hex binding))
        (List.assoc_opt "SMOLVM_INTERCEPTOR_TOKEN" request.Process_runner.env);
      ignore (Smolvm.exec smolvm (name_exn "work") [ "env" ]);
      Alcotest.(check bool) "exec gets no mediation token" false
        (List.mem_assoc "SMOLVM_INTERCEPTOR_TOKEN" (List.hd !recorder).Process_runner.env))

let failure_status_is_reported () =
  let recorder = ref [] in
  let smolvm = adapter (fake ~status:2 ~stderr:"boom" recorder) in
  match Smolvm.stop smolvm (name_exn "work") with
  | Error (Ade_error.Runtime_failed { status; _ }) ->
      Alcotest.(check int) "status" 2 status
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)
  | Ok () -> Alcotest.fail "expected a nonzero status to be reported"

let () =
  Alcotest.run "smolvm"
    [ ( "state",
        [ Alcotest.test_case "created" `Quick (state_case "created" "created");
          Alcotest.test_case "running" `Quick (state_case "running" "running");
          Alcotest.test_case "ready" `Quick (state_case "ready" "running");
          Alcotest.test_case "booting" `Quick (state_case "booting" "running");
          Alcotest.test_case "stopped" `Quick (state_case "stopped" "stopped");
          Alcotest.test_case "stopping" `Quick (state_case "stopping" "stopped");
          Alcotest.test_case "failed" `Quick (state_case "failed: boom" "stopped");
          Alcotest.test_case "unknown" `Quick unknown_state_is_rejected;
          Alcotest.test_case "malformed json" `Quick malformed_json_is_reported;
          Alcotest.test_case "absent" `Quick missing_machine_is_absent;
          Alcotest.test_case "running via json" `Quick running_state_is_parsed ] );
      ( "create",
        [ Alcotest.test_case "declaration" `Quick create_argv_follows_the_declaration;
          Alcotest.test_case "sealed" `Quick sealed_declaration_creates_no_network;
          Alcotest.test_case "proxied" `Quick proxied_declaration_reaches_only_its_proxy;
          Alcotest.test_case "mounts" `Quick create_argv_carries_resolved_mounts;
          Alcotest.test_case "ssh agent" `Quick dedicated_ssh_requests_agent_forwarding ] );
      ( "execution",
        [ Alcotest.test_case "attach inherits" `Quick attach_inherits_the_terminal;
          Alcotest.test_case "exec captures" `Quick exec_captures_output;
          Alcotest.test_case "ssh socket" `Quick ssh_socket_never_reaches_argv;
          Alcotest.test_case "guard token" `Quick guard_token_is_only_in_the_host_start_environment;
          Alcotest.test_case "failure" `Quick failure_status_is_reported;
          Alcotest.test_case "stdin needs -i" `Quick piped_stdin_keeps_stdin_open;
          Alcotest.test_case "delete forced" `Quick delete_is_forced;
          Alcotest.test_case "bare attach" `Quick attach_without_a_command_opens_a_shell;
          Alcotest.test_case "attach command" `Quick attach_with_a_command_execs_on_a_terminal ] )
    ]
