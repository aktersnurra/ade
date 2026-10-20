open Ade

(* One ordered log of everything that happens, host effects and runtime calls
   alike, so the tests can assert sequence: agent before boot, credentials
   after it, and undo in reverse. *)
type world = {
  mutable log : string list;
  mutable start_env : (string * string) list;
  mutable fail_start : bool;
  mutable fail_credentials : bool;
  mutable agent_mode : Ssh_agent.mode option;
  mutable agent_identity : string option;
}

let fresh () =
  {
    log = [];
    start_env = [];
    fail_start = false;
    fail_credentials = false;
    agent_mode = None;
    agent_identity = None;
  }

let note world entry = world.log <- entry :: world.log
let events world = List.rev world.log

let ok = Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let runner world request =
  match request.Process_runner.argv with
  | "machine" :: "start" :: _ ->
      note world "machine start";
      world.start_env <- request.Process_runner.env;
      if world.fail_start then
        Ok { Process_runner.status = 1; stdout = ""; stderr = "boot failed" }
      else ok
  | "machine" :: verb :: _ ->
      note world ("machine " ^ verb);
      ok
  | _ -> ok

(* The agent's socket is a real file, so release sees a live agent and stops
   it, the way it would on a host. *)
let socket_file () =
  let path = Filename.temp_file "ade-agent-" ".sock" in
  path

let services world =
  {
    Boot.start_agent =
      (fun ~name:_ ~mode ~identity ->
        world.agent_mode <- Some mode;
        world.agent_identity <- Option.map Secret.describe identity;
        note world "agent start";
        Ok
          (Ssh_agent.of_record ~socket:(socket_file ()) ~pid:"4242"
             ~populated:(mode = Ssh_agent.Populated)));
    stop_agent =
      (fun _ ->
        note world "agent stop";
        Ok ());
    install_credentials =
      (fun ~smolvm:_ ~name:_ _ ->
        note world "credentials";
        if world.fail_credentials then
          Error (Ade_error.Operation_refused { operation = "credentials"; reason = "boom" })
        else Ok ());
  }

let temp_root () =
  let path = Filename.temp_file "ade-boot-" "" in
  Sys.remove path;
  path

let declaration_with ~ssh =
  let path = Filename.temp_file "ade-boot-" ".toml" in
  let channel = open_out path in
  output_string channel
    (Printf.sprintf
       {|name = "work"
image = "docker.io/library/ade@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
smolfile = "smolfiles/workstation.Smolfile"

[resources]
cpus = 2
memory_mib = 2048
overlay_gib = 8
workspace_gib = 16

[network]
posture = "sealed"

%s

[backup]
directory = "/tmp/ade-backups"
|}
       ssh);
  close_out channel;
  match Declaration.load path with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

let with_agent () = declaration_with ~ssh:"[ssh]\nmode = \"dedicated_agent\"\nkey_ref = \"pass:ade/work-ssh\""
let without_agent () = declaration_with ~ssh:"[ssh]\nmode = \"disabled\""

let setup () =
  let world = fresh () in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner world) in
  let paths = State_paths.make ~root:(temp_root ()) () in
  (world, smolvm, paths)

let name declaration = Declaration.name declaration

let start ?(purpose = Boot.Work) world smolvm paths declaration =
  Boot.start ~services:(services world) ~smolvm ~paths ~name:(name declaration) ~purpose
    declaration

let record_exists paths declaration =
  Sys.file_exists (State_paths.ssh_agent_file paths (name declaration))

let expect_ok label = function
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s: %s" label (Ade_error.to_string error)

let expect_error label = function
  | Ok () -> Alcotest.failf "%s: expected failure" label
  | Error _ -> ()

let log = Alcotest.(list string)

(* The agent must exist before boot, since the runtime forwards its socket at
   start; credentials need a running guest. *)
let work_start_orders_agent_boot_credentials () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  expect_ok "start" (start world smolvm paths declaration);
  Alcotest.check log "order" [ "agent start"; "machine start"; "credentials" ] (events world);
  Alcotest.(check bool) "populated" true (world.agent_mode = Some Ssh_agent.Populated);
  Alcotest.(check (option string)) "declared identity" (Some "pass entry ade/work-ssh")
    world.agent_identity;
  Alcotest.(check bool) "socket forwarded" true (List.mem_assoc "SSH_AUTH_SOCK" world.start_env);
  Alcotest.(check bool) "recorded" true (record_exists paths declaration)

(* A maintenance window boots an untrusted guest: no identity, no credentials. *)
let maintenance_start_is_unarmed () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  expect_ok "start" (start ~purpose:Boot.Maintenance world smolvm paths declaration);
  Alcotest.check log "order" [ "agent start"; "machine start" ] (events world);
  Alcotest.(check bool) "empty" true (world.agent_mode = Some Ssh_agent.Empty);
  Alcotest.(check (option string)) "no identity" None world.agent_identity

let no_agent_without_ssh () =
  let world, smolvm, paths = setup () in
  let declaration = without_agent () in
  expect_ok "start" (start world smolvm paths declaration);
  Alcotest.check log "order" [ "machine start"; "credentials" ] (events world);
  Alcotest.(check bool) "no socket" false (List.mem_assoc "SSH_AUTH_SOCK" world.start_env);
  Alcotest.(check bool) "no record" false (record_exists paths declaration)

let failed_boot_stops_the_agent () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  world.fail_start <- true;
  expect_error "start" (start world smolvm paths declaration);
  Alcotest.check log "undone" [ "agent start"; "machine start"; "agent stop" ] (events world);
  Alcotest.(check bool) "forgotten" false (record_exists paths declaration)

(* Without its credentials the workbench is not what was declared, so it is
   left stopped and a retry starts from scratch. *)
let failed_credentials_stop_machine_and_agent () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  world.fail_credentials <- true;
  expect_error "start" (start world smolvm paths declaration);
  Alcotest.check log "undone"
    [ "agent start"; "machine start"; "credentials"; "machine stop"; "agent stop" ]
    (events world);
  Alcotest.(check bool) "forgotten" false (record_exists paths declaration)

(* A record left by a process that died is stopped, never reused. *)
let leftover_agent_is_stopped_first () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  expect_ok "first" (start world smolvm paths declaration);
  world.log <- [];
  expect_ok "second" (start world smolvm paths declaration);
  Alcotest.check log "replaced"
    [ "agent stop"; "agent start"; "machine start"; "credentials" ] (events world)

(* A dead agent's pid may belong to another process by now. *)
let dead_agent_is_not_signalled () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  expect_ok "start" (start world smolvm paths declaration);
  (match Boot.release_agent ~services:(services world) ~paths (name declaration) with
   | _ -> ());
  world.log <- [];
  let path = State_paths.ssh_agent_file paths (name declaration) in
  let channel = open_out path in
  output_string channel "/nonexistent/agent.sock\n4242\ntrue\n";
  close_out channel;
  expect_ok "release" (Boot.release_agent ~services:(services world) ~paths (name declaration));
  Alcotest.check log "not signalled" [] (events world);
  Alcotest.(check bool) "forgotten" false (Sys.file_exists path)

let stop_halts_machine_then_agent () =
  let world, smolvm, paths = setup () in
  let declaration = with_agent () in
  expect_ok "start" (start world smolvm paths declaration);
  world.log <- [];
  expect_ok "stop" (Boot.stop ~services:(services world) ~smolvm ~paths (name declaration));
  Alcotest.check log "order" [ "machine stop"; "agent stop" ] (events world);
  Alcotest.(check bool) "forgotten" false (record_exists paths declaration)

let () =
  Alcotest.run "boot"
    [
      ( "start",
        [ Alcotest.test_case "work" `Quick work_start_orders_agent_boot_credentials;
          Alcotest.test_case "maintenance" `Quick maintenance_start_is_unarmed;
          Alcotest.test_case "no ssh" `Quick no_agent_without_ssh;
          Alcotest.test_case "leftover agent" `Quick leftover_agent_is_stopped_first;
          Alcotest.test_case "dead agent" `Quick dead_agent_is_not_signalled ] );
      ( "rollback",
        [ Alcotest.test_case "boot fails" `Quick failed_boot_stops_the_agent;
          Alcotest.test_case "credentials fail" `Quick failed_credentials_stop_machine_and_agent ] );
      ( "stop", [ Alcotest.test_case "order" `Quick stop_halts_machine_then_agent ] );
    ]
