open Ade

(* Host effects are inert here: no real ssh-agent, no GitHub. Boot's own
   sequencing is tested in test_boot. *)
let services =
  {
    Boot.start_agent =
      (fun ~name:_ ~mode ~identity:_ ->
        Ok
          (Ssh_agent.of_record ~socket:"/nonexistent/agent.sock" ~pid:"0"
             ~populated:(mode = Ssh_agent.Populated)));
    stop_agent = (fun _ -> Ok ());
    install_credentials = (fun ~smolvm:_ ~name:_ _ -> Ok ());
  }

(* A scripted fake runtime: it holds a machine state that create/start/stop
   mutate, so convergence is tested as a state machine rather than by asserting
   on command strings. *)
type fake = {
  mutable state : string;
  mutable calls : string list;
  mutable last_argv : string list;
  mutable stdins : string list;
  mutable exec_status : int;
}

let runner fake request =
  let subcommand =
    match request.Process_runner.argv with
    | _ :: verb :: _ -> verb
    | _ -> ""
  in
  fake.calls <- subcommand :: fake.calls;
  fake.last_argv <- request.Process_runner.argv;
  Option.iter (fun stdin -> fake.stdins <- stdin :: fake.stdins) request.Process_runner.stdin;
  match subcommand with
  | "status" ->
      if fake.state = "absent" then
        Ok { Process_runner.status = 1; stdout = ""; stderr = "machine 'work' not found" }
      else
        Ok
          {
            Process_runner.status = 0;
            stdout = Printf.sprintf {|{"name":"work","state":"%s"}|} fake.state;
            stderr = "";
          }
  | "create" ->
      fake.state <- "created";
      Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "start" ->
      fake.state <- "running";
      Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "stop" ->
      fake.state <- "stopped";
      Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | "exec" ->
      Ok { Process_runner.status = fake.exec_status; stdout = ""; stderr = "pacman: boom" }
  | "delete" ->
      fake.state <- "absent";
      Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
  | _ -> Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let temp_root () =
  let path = Filename.temp_file "ade-state-" "" in
  Sys.remove path;
  path

let setup_with_paths initial =
  let fake = { state = initial; calls = []; last_argv = []; stdins = []; exec_status = 0 } in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake) in
  let paths = State_paths.make ~root:(temp_root ()) () in
  (fake, paths, Lifecycle.make ~services ~smolvm ~paths)

let setup initial =
  let fake, _, lifecycle = setup_with_paths initial in
  (fake, lifecycle)

let declaration () =
  match Declaration.load "../workbenches/work.toml" with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

let outcome = Alcotest.testable
  (fun fmt -> function
    | Lifecycle.Converged -> Format.fprintf fmt "converged"
    | Lifecycle.Changed -> Format.fprintf fmt "changed")
  ( = )

let check_outcome label expected = function
  | Ok actual -> Alcotest.check outcome label expected actual
  | Error error -> Alcotest.failf "%s: %s" label (Ade_error.to_string error)

let creating_an_absent_machine_creates_it () =
  let fake, lifecycle = setup "absent" in
  check_outcome "create" Lifecycle.Changed (Lifecycle.create lifecycle (declaration ()));
  Alcotest.(check string) "state" "created" fake.state

let creating_an_existing_machine_converges () =
  let fake, lifecycle = setup "stopped" in
  check_outcome "create" Lifecycle.Converged (Lifecycle.create lifecycle (declaration ()));
  Alcotest.(check bool) "does not recreate" false (List.mem "create" fake.calls)

let starting_a_running_machine_converges () =
  let _, lifecycle = setup "running" in
  check_outcome "start" Lifecycle.Converged (Lifecycle.start lifecycle (declaration ()))

let starting_a_stopped_machine_starts_it () =
  let fake, lifecycle = setup "stopped" in
  check_outcome "start" Lifecycle.Changed (Lifecycle.start lifecycle (declaration ()));
  Alcotest.(check string) "state" "running" fake.state

let stopping_a_stopped_machine_converges () =
  let _, lifecycle = setup "stopped" in
  check_outcome "stop" Lifecycle.Converged (Lifecycle.stop lifecycle (declaration ()))

let stopping_a_running_machine_stops_it () =
  let fake, lifecycle = setup "running" in
  check_outcome "stop" Lifecycle.Changed (Lifecycle.stop lifecycle (declaration ()));
  Alcotest.(check string) "state" "stopped" fake.state

let restarting_a_stopped_machine_starts_it () =
  let fake, lifecycle = setup "stopped" in
  check_outcome "restart" Lifecycle.Changed (Lifecycle.restart lifecycle (declaration ()));
  Alcotest.(check string) "state" "running" fake.state

(* A bare attach to a Herdr workbench lands in Herdr; an explicit command is
   run as given. *)
let bare_attach_opens_herdr () =
  let fake, lifecycle = setup "running" in
  (match Lifecycle.attach lifecycle (declaration ()) ~command:[] with
   | Ok () -> ()
   | Error error -> Alcotest.failf "attach: %s" (Ade_error.to_string error));
  Alcotest.(check (list string)) "herdr" [ "--"; "herdr" ]
    (match List.rev fake.last_argv with
     | last :: dashdash :: _ -> [ dashdash; last ]
     | _ -> []);
  (match Lifecycle.attach lifecycle (declaration ()) ~command:[ "bash" ] with
   | Ok () -> ()
   | Error error -> Alcotest.failf "attach: %s" (Ade_error.to_string error));
  Alcotest.(check string) "explicit" "bash" (List.nth fake.last_argv (List.length fake.last_argv - 1))

(* Removal stops a running machine first, then deletes it and forgets its
   state directory, so the name can be reused from scratch. *)
let removing_a_running_machine_deletes_it_and_its_state () =
  let fake, paths, lifecycle = setup_with_paths "running" in
  let declaration = declaration () in
  let dir = State_paths.workbench_dir paths (Declaration.name declaration) in
  (match State_paths.ensure_dir (Filename.concat dir "credentials") with
   | Ok () -> ()
   | Error error -> Alcotest.failf "ensure_dir: %s" (Ade_error.to_string error));
  check_outcome "remove" Lifecycle.Changed (Lifecycle.remove lifecycle declaration);
  Alcotest.(check string) "state" "absent" fake.state;
  Alcotest.(check bool) "stopped first" true (List.mem "stop" fake.calls);
  Alcotest.(check bool) "state dir gone" false (Sys.file_exists dir)

let removing_an_absent_machine_converges () =
  let _, lifecycle = setup "absent" in
  check_outcome "remove" Lifecycle.Converged (Lifecycle.remove lifecycle (declaration ()))

(* Provisioning installs the guest's tooling once, in a window where the guest
   has no identity and no credentials; the machine is stopped afterwards. *)
let provisioned_declaration () =
  let script = Filename.temp_file "ade-provision-" ".sh" in
  let channel = open_out script in
  output_string channel "echo provisioned\n";
  close_out channel;
  let path = Filename.temp_file "ade-decl-" ".toml" in
  let channel = open_out path in
  Printf.fprintf channel
    {|name = "work"
image = "docker.io/menci/archlinuxarm:base-devel"
provision = "%s"

[resources]
cpus = 2
memory_mib = 2048
overlay_gib = 8
workspace_gib = 16

[network]
posture = "public"

[backup]
directory = "/tmp/b"
keep = 1
|}
    script;
  close_out channel;
  match Declaration.load path with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

let calls fake = List.rev fake.calls

let creating_provisions_once_then_stops () =
  let fake, lifecycle = setup "absent" in
  check_outcome "create" Lifecycle.Changed
    (Lifecycle.create lifecycle (provisioned_declaration ()));
  Alcotest.(check (list string)) "order" [ "create"; "start"; "exec"; "stop" ]
    (List.filter (fun c -> c <> "status") (calls fake));
  Alcotest.(check (list string)) "script on stdin" [ "echo provisioned\n" ] fake.stdins;
  Alcotest.(check string) "stopped" "stopped" fake.state

let a_failed_provision_stops_the_machine_and_reports () =
  let fake, lifecycle = setup "absent" in
  fake.exec_status <- 1;
  (match Lifecycle.create lifecycle (provisioned_declaration ()) with
   | Ok _ -> Alcotest.fail "expected the failed script to be an error"
   | Error _ -> ());
  Alcotest.(check string) "stopped" "stopped" fake.state

let provision_reruns_on_a_stopped_machine () =
  let fake, lifecycle = setup "stopped" in
  check_outcome "provision" Lifecycle.Changed
    (Lifecycle.provision lifecycle (provisioned_declaration ()));
  Alcotest.(check int) "ran" 1 (List.length fake.stdins);
  Alcotest.(check string) "stopped" "stopped" fake.state

let provision_refuses_a_running_machine () =
  let fake, lifecycle = setup "running" in
  (match Lifecycle.provision lifecycle (provisioned_declaration ()) with
   | Ok _ -> Alcotest.fail "expected a refusal"
   | Error _ -> ());
  Alcotest.(check (list string)) "nothing ran" [] fake.stdins

let provision_without_a_script_is_refused () =
  let _, lifecycle = setup "stopped" in
  match Lifecycle.provision lifecycle (declaration ()) with
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error _ -> ()

let attaching_to_a_stopped_machine_starts_it () =
  let fake, lifecycle = setup "stopped" in
  (match Lifecycle.attach lifecycle (declaration ()) ~command:[] with
   | Ok () -> ()
   | Error error -> Alcotest.failf "attach: %s" (Ade_error.to_string error));
  Alcotest.(check string) "state" "running" fake.state;
  Alcotest.(check bool) "attached" true (List.mem "shell" fake.calls)

(* Repeating any command must reach the same end state. *)
let commands_are_idempotent () =
  let fake, lifecycle = setup "absent" in
  let declaration = declaration () in
  for _ = 1 to 3 do
    ignore (Lifecycle.create lifecycle declaration);
    ignore (Lifecycle.start lifecycle declaration)
  done;
  Alcotest.(check string) "state" "running" fake.state;
  let creates = List.length (List.filter (fun c -> c = "create") fake.calls) in
  Alcotest.(check int) "created exactly once" 1 creates

let status_reports_observed_state () =
  let _, lifecycle = setup "running" in
  match Lifecycle.status lifecycle (declaration ()) with
  | Error error -> Alcotest.failf "status: %s" (Ade_error.to_string error)
  | Ok status ->
      Alcotest.(check string) "name" "work" status.Lifecycle.name;
      Alcotest.(check bool) "running" true (status.Lifecycle.state = Smolvm.Running)

(* Two operations on one workbench must not run concurrently. *)
let the_lock_excludes_a_second_operation () =
  let paths = State_paths.make ~root:(temp_root ()) () in
  let name =
    match Workbench_name.of_string "work" with
    | Ok name -> name
    | Error _ -> Alcotest.fail "name"
  in
  match Workbench_lock.acquire paths name with
  | Error error -> Alcotest.failf "first acquire: %s" (Ade_error.to_string error)
  | Ok lock -> (
      (match Workbench_lock.acquire paths name with
       | Ok _ -> Alcotest.fail "expected the second acquisition to be refused"
       | Error _ -> ());
      Workbench_lock.release lock;
      match Workbench_lock.acquire paths name with
      | Ok lock -> Workbench_lock.release lock
      | Error error -> Alcotest.failf "reacquire: %s" (Ade_error.to_string error))

let () =
  Alcotest.run "lifecycle"
    [ ( "create",
        [ Alcotest.test_case "absent" `Quick creating_an_absent_machine_creates_it;
          Alcotest.test_case "existing" `Quick creating_an_existing_machine_converges ] );
      ( "start and stop",
        [ Alcotest.test_case "running" `Quick starting_a_running_machine_converges;
          Alcotest.test_case "stopped" `Quick starting_a_stopped_machine_starts_it;
          Alcotest.test_case "stop stopped" `Quick stopping_a_stopped_machine_converges;
          Alcotest.test_case "stop running" `Quick stopping_a_running_machine_stops_it;
          Alcotest.test_case "restart" `Quick restarting_a_stopped_machine_starts_it ] );
      ( "remove",
        [ Alcotest.test_case "running" `Quick removing_a_running_machine_deletes_it_and_its_state;
          Alcotest.test_case "absent" `Quick removing_an_absent_machine_converges ] );
      ( "provision",
        [ Alcotest.test_case "on create" `Quick creating_provisions_once_then_stops;
          Alcotest.test_case "failure" `Quick a_failed_provision_stops_the_machine_and_reports;
          Alcotest.test_case "rerun" `Quick provision_reruns_on_a_stopped_machine;
          Alcotest.test_case "running" `Quick provision_refuses_a_running_machine;
          Alcotest.test_case "no script" `Quick provision_without_a_script_is_refused ] );
      ( "attach",
        [ Alcotest.test_case "starts first" `Quick attaching_to_a_stopped_machine_starts_it;
          Alcotest.test_case "herdr by default" `Quick bare_attach_opens_herdr ] );
      ( "convergence",
        [ Alcotest.test_case "idempotent" `Quick commands_are_idempotent;
          Alcotest.test_case "status" `Quick status_reports_observed_state;
          Alcotest.test_case "lock" `Quick the_lock_excludes_a_second_operation ] )
    ]
