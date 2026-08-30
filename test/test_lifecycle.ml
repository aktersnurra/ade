open Ade

(* A scripted fake runtime: it holds a machine state that create/start/stop
   mutate, so convergence is tested as a state machine rather than by asserting
   on command strings. *)
type fake = { mutable state : string; mutable calls : string list }

let runner fake request =
  let subcommand =
    match request.Process_runner.argv with
    | _ :: verb :: _ -> verb
    | _ -> ""
  in
  fake.calls <- subcommand :: fake.calls;
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
  | _ -> Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let temp_root () =
  let path = Filename.temp_file "ade-state-" "" in
  Sys.remove path;
  path

let setup initial =
  let fake = { state = initial; calls = [] } in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake) in
  let paths = State_paths.make ~root:(temp_root ()) () in
  (fake, Lifecycle.make ~smolvm ~paths)

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
      ( "attach",
        [ Alcotest.test_case "starts first" `Quick attaching_to_a_stopped_machine_starts_it ] );
      ( "convergence",
        [ Alcotest.test_case "idempotent" `Quick commands_are_idempotent;
          Alcotest.test_case "status" `Quick status_reports_observed_state;
          Alcotest.test_case "lock" `Quick the_lock_excludes_a_second_operation ] )
    ]
