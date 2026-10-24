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
    start_proxy = (fun _ -> Ok ());
    ensure_proxy = (fun _ -> Ok ());
    stop_proxy = (fun _ -> Ok ());
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

(* The shipped declaration without its provision line, so these tests are about
   convergence alone; provisioning has its own group below. [edit] rewrites
   whole lines, for tests that change the declaration after creation. *)
let declaration ?(edit = Fun.id) () =
  let source = In_channel.with_open_bin "../workbenches/work.toml" In_channel.input_all in
  let kept =
    String.split_on_char '\n' source
    |> List.filter (fun line -> not (String.starts_with ~prefix:"provision = " line))
    |> List.map edit
  in
  let path = Filename.temp_file "ade-work-" ".toml" in
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel (String.concat "\n" kept));
  match Declaration.load path with
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

|}
    script;
  close_out channel;
  match Declaration.load path with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)

(* A machine keeps what it was created with: resources, network, the SSH
   forwarding switch and mounts. Editing those afterwards is drift, reported by
   status and create; editing what applies at every start is not. *)
let contains text affix =
  let n = String.length affix in
  let rec at i = i + n <= String.length text && (String.sub text i n = affix || at (i + 1)) in
  at 0

let replace_line ~prefix ~by line = if String.starts_with ~prefix line then by else line

let drift_of lifecycle declaration =
  match Lifecycle.status lifecycle declaration with
  | Ok status -> status.Lifecycle.drift
  | Error error -> Alcotest.failf "status: %s" (Ade_error.to_string error)

let created lifecycle declaration =
  check_outcome "create" Lifecycle.Changed (Lifecycle.create lifecycle declaration)

let unchanged_declaration_has_no_drift () =
  let _, lifecycle = setup "absent" in
  created lifecycle (declaration ());
  Alcotest.(check (option string)) "drift" None (drift_of lifecycle (declaration ()))

let changed_resources_are_drift () =
  let _, lifecycle = setup "absent" in
  created lifecycle (declaration ());
  let edited = declaration ~edit:(replace_line ~prefix:"cpus = " ~by:"cpus = 2") () in
  (match drift_of lifecycle edited with
   | Some reason ->
       if not (contains reason "resources") then
         Alcotest.failf "drift does not name resources: %s" reason
   | None -> Alcotest.fail "a resource change was not reported");
  match Lifecycle.create lifecycle edited with
  | Ok _ -> Alcotest.fail "create converged on a drifted machine"
  | Error _ -> ()

let a_new_mount_is_drift () =
  let _, lifecycle = setup "absent" in
  created lifecycle (declaration ());
  let edited =
    declaration
      ~edit:(replace_line ~prefix:"[ssh]"
               ~by:"[[mount]]\nhost = \"/srv/data\"\nguest = \"/data\"\n\n[ssh]")
      ()
  in
  match drift_of lifecycle edited with
  | Some reason ->
      if not (contains reason "mounts") then
        Alcotest.failf "drift does not name mounts: %s" reason
  | None -> Alcotest.fail "a new mount was not reported"

let start_time_settings_are_not_drift () =
  let _, lifecycle = setup "absent" in
  created lifecycle (declaration ());
  let edited =
    declaration
      ~edit:(fun line ->
        line
        |> replace_line ~prefix:"herdr = " ~by:"herdr = false"
        |> replace_line ~prefix:"key_ref = " ~by:"key_ref = \"pass:other\"")
      ()
  in
  Alcotest.(check (option string)) "drift" None (drift_of lifecycle edited)

(* A machine ADE has no record for, made before records existed or outside
   ADE, cannot be compared, and is not reported as drifted. *)
let a_machine_without_a_record_has_no_drift () =
  let _, lifecycle = setup "stopped" in
  Alcotest.(check (option string)) "drift" None (drift_of lifecycle (declaration ()))

let removing_forgets_the_record () =
  let _, lifecycle = setup "absent" in
  created lifecycle (declaration ());
  check_outcome "remove" Lifecycle.Changed (Lifecycle.remove lifecycle (declaration ()));
  let edited = declaration ~edit:(replace_line ~prefix:"cpus = " ~by:"cpus = 2") () in
  created lifecycle edited;
  Alcotest.(check (option string)) "drift" None (drift_of lifecycle edited)

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
  (* work.toml enables Herdr, so the attachment is an interactive exec of it. *)
  Alcotest.(check bool) "attached" true (List.mem "herdr" fake.last_argv)

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

let lock_name () =
  match Workbench_name.of_string "work" with
  | Ok name -> name
  | Error _ -> Alcotest.fail "name"

(* A crash leaves the lock file behind. The lock is a kernel record lock, held
   by a process rather than by the file existing, so a leftover file must not
   block the workbench forever. *)
let a_leftover_lock_file_does_not_block () =
  let paths = State_paths.make ~root:(temp_root ()) () in
  let name = lock_name () in
  let file = State_paths.lock_file paths name in
  (match State_paths.ensure_dir (Filename.dirname file) with
   | Ok () -> ()
   | Error error -> Alcotest.failf "ensure_dir: %s" (Ade_error.to_string error));
  Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel "99999\n");
  match Workbench_lock.acquire paths name with
  | Ok lock -> Workbench_lock.release lock
  | Error error -> Alcotest.failf "acquire: %s" (Ade_error.to_string error)

(* The same refusal must hold across processes, which the in-process table
   cannot see, and must be a policy refusal rather than bad runtime output. *)
let another_process_holding_the_lock_refuses () =
  let paths = State_paths.make ~root:(temp_root ()) () in
  let name = lock_name () in
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      (* The child's copy of the write end must close, or it never sees EOF. *)
      Unix.close release_write;
      (match Workbench_lock.acquire paths name with
       | Ok _ -> ignore (Unix.write_substring ready_write "1" 0 1)
       | Error _ -> ignore (Unix.write_substring ready_write "0" 0 1));
      ignore (Unix.read release_read (Bytes.create 1) 0 1);
      Unix._exit 0
  | child ->
      let flag = Bytes.create 1 in
      ignore (Unix.read ready_read flag 0 1);
      if Bytes.to_string flag <> "1" then Alcotest.fail "the child could not take the lock";
      (match Workbench_lock.acquire paths name with
       | Ok _ -> Alcotest.fail "expected the other process's lock to be respected"
       | Error (Ade_error.Operation_refused _) -> ()
       | Error error -> Alcotest.failf "wrong error: %s" (Ade_error.to_string error));
      Unix.close release_write;
      ignore (Unix.waitpid [] child);
      (match Workbench_lock.acquire paths name with
       | Ok lock -> Workbench_lock.release lock
       | Error error ->
           Alcotest.failf "lock not released with its owner: %s" (Ade_error.to_string error))

(* Refresh only ever installs into a running machine that has a GitHub App;
   anything else is left for the next start, which mints anyway. *)
let refresh_with ~state ~github =
  let installs = ref 0 in
  let services =
    { services with
      Boot.install_credentials = (fun ~smolvm:_ ~name:_ _ -> incr installs; Ok ()) }
  in
  let fake = { state; calls = []; last_argv = []; stdins = []; exec_status = 0 } in
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner fake) in
  let paths = State_paths.make ~root:(temp_root ()) () in
  let lifecycle = Lifecycle.make ~services ~smolvm ~paths in
  let base = declaration () in
  let declaration =
    if not github then base
    else
      let source = In_channel.with_open_bin (Declaration.path base) In_channel.input_all in
      let path = Filename.temp_file "ade-work-" ".toml" in
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel
            (source ^ "\n[credentials.github]\napp_id = \"1\"\n"));
      match Declaration.load path with
      | Ok declaration -> declaration
      | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  in
  let result = Lifecycle.refresh lifecycle declaration in
  (result, !installs, fake)

let refreshing_a_running_machine_installs () =
  let result, installs, fake = refresh_with ~state:"running" ~github:true in
  check_outcome "refresh" Lifecycle.Changed result;
  Alcotest.(check int) "installed once" 1 installs;
  Alcotest.(check string) "still running" "running" fake.state

let refreshing_a_stopped_machine_converges () =
  let result, installs, fake = refresh_with ~state:"stopped" ~github:true in
  check_outcome "refresh" Lifecycle.Converged result;
  Alcotest.(check int) "nothing installed" 0 installs;
  Alcotest.(check string) "not started" "stopped" fake.state

let refreshing_without_github_converges () =
  let result, installs, _ = refresh_with ~state:"running" ~github:false in
  check_outcome "refresh" Lifecycle.Converged result;
  Alcotest.(check int) "nothing installed" 0 installs

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
      ( "drift",
        [ Alcotest.test_case "unchanged" `Quick unchanged_declaration_has_no_drift;
          Alcotest.test_case "resources" `Quick changed_resources_are_drift;
          Alcotest.test_case "new mount" `Quick a_new_mount_is_drift;
          Alcotest.test_case "start-time settings" `Quick start_time_settings_are_not_drift;
          Alcotest.test_case "no record" `Quick a_machine_without_a_record_has_no_drift;
          Alcotest.test_case "rm forgets" `Quick removing_forgets_the_record ] );
      ( "provision",
        [ Alcotest.test_case "on create" `Quick creating_provisions_once_then_stops;
          Alcotest.test_case "failure" `Quick a_failed_provision_stops_the_machine_and_reports;
          Alcotest.test_case "rerun" `Quick provision_reruns_on_a_stopped_machine;
          Alcotest.test_case "running" `Quick provision_refuses_a_running_machine;
          Alcotest.test_case "no script" `Quick provision_without_a_script_is_refused ] );
      ( "refresh",
        [ Alcotest.test_case "running" `Quick refreshing_a_running_machine_installs;
          Alcotest.test_case "stopped" `Quick refreshing_a_stopped_machine_converges;
          Alcotest.test_case "no github" `Quick refreshing_without_github_converges ] );
      ( "attach",
        [ Alcotest.test_case "starts first" `Quick attaching_to_a_stopped_machine_starts_it;
          Alcotest.test_case "herdr by default" `Quick bare_attach_opens_herdr ] );
      ( "convergence",
        [ Alcotest.test_case "idempotent" `Quick commands_are_idempotent;
          Alcotest.test_case "status" `Quick status_reports_observed_state;
          Alcotest.test_case "lock" `Quick the_lock_excludes_a_second_operation;
          Alcotest.test_case "leftover lock file" `Quick a_leftover_lock_file_does_not_block;
          Alcotest.test_case "other process" `Quick another_process_holding_the_lock_refuses ] )
    ]
