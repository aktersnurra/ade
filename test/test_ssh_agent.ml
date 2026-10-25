open Ade

let key_bytes = "FAKE" ^ "-private-key-bytes"

let agent_output socket pid =
  Printf.sprintf "SSH_AUTH_SOCK=%s; export SSH_AUTH_SOCK;\nSSH_AGENT_PID=%s; export SSH_AGENT_PID;\n"
    socket pid

type fake = { mutable requests : Process_runner.request list }

(* A fake host: ssh-agent reports a socket, ssh-add succeeds, ssh-add -l
   reports whatever the test asks for. *)
let runner ?(identities = 0) fake request =
  fake.requests <- fake.requests @ [ request ];
  let is exe = Filename.basename request.Process_runner.executable = exe in
  if is "ssh-agent" && List.mem "-s" request.Process_runner.argv then
    Ok
      {
        Process_runner.status = 0;
        stdout = agent_output "/tmp/ade-agent.sock" "4242";
        stderr = "";
      }
  else if is "ssh-add" && List.mem "-l" request.Process_runner.argv then
    if identities = 0 then
      Ok { Process_runner.status = 1; stdout = ""; stderr = "The agent has no identities." }
    else
      Ok
        {
          Process_runner.status = 0;
          stdout = String.concat "\n" (List.init identities (fun i -> Printf.sprintf "256 SHA256:key%d" i));
          stderr = "";
        }
  else Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let setup ?identities () =
  let fake = { requests = [] } in
  (fake, runner ?identities fake)

let paths () = State_paths.make ~root:"/tmp/ade-ssh-test" ()

let name_exn value =
  match Workbench_name.of_string value with
  | Ok n -> n
  | Error _ -> Alcotest.failf "bad name %s" value

let identity_file () =
  let path = Filename.temp_file "ade-ssh-" ".key" in
  let channel = open_out path in
  output_string channel key_bytes;
  close_out channel;
  Secret.file ~path

let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let start ?identities ?mode () =
  let fake, runner = setup ?identities () in
  let mode = match mode with Some mode -> mode | None -> Ssh_agent.With_identity (identity_file ()) in
  (fake, Ssh_agent.start ~runner ~paths:(paths ()) ~name:(name_exn "work") ~mode ())

let a_populated_agent_loads_the_identity () =
  let fake, result = start () in
  match result with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent ->
      Alcotest.(check bool) "populated" true (Ssh_agent.is_populated agent);
      Alcotest.(check bool) "ran ssh-add" true
        (List.exists
           (fun r ->
             Filename.basename r.Process_runner.executable = "ssh-add"
             && List.mem "-" r.Process_runner.argv)
           fake.requests)

(* The design requires an empty agent during maintenance: the export helper
   runs in a guest ADE does not trust and must not be able to sign. *)
let a_maintenance_agent_stays_empty () =
  let fake, result = start ~mode:Ssh_agent.Empty () in
  match result with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent ->
      Alcotest.(check bool) "not populated" false (Ssh_agent.is_populated agent);
      Alcotest.(check bool) "never ran ssh-add" false
        (List.exists
           (fun r -> Filename.basename r.Process_runner.executable = "ssh-add")
           fake.requests)

(* The key must reach ssh-add on stdin, never as an argument. *)
let the_key_never_reaches_argv () =
  let fake, result = start () in
  (match result with
   | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
   | Ok _ -> ());
  List.iter
    (fun r ->
      List.iter
        (fun argument ->
          if contains argument key_bytes then
            Alcotest.failf "the key appeared in argv: %s" argument)
        r.Process_runner.argv;
      List.iter
        (fun (k, v) ->
          if contains v key_bytes then
            Alcotest.failf "the key appeared in the environment as %s" k)
        r.Process_runner.env)
    fake.requests

let the_key_travels_on_stdin () =
  let fake, _ = start () in
  Alcotest.(check bool) "on stdin" true
    (List.exists
       (fun r -> r.Process_runner.stdin = Some key_bytes)
       fake.requests)

let the_socket_is_read_from_the_agent () =
  let _, result = start () in
  match result with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent ->
      Alcotest.(check string) "socket" "/tmp/ade-agent.sock" (Ssh_agent.socket_path agent)

(* An empty agent must be observably empty, not merely assumed to be. *)
let an_empty_agent_reports_no_identities () =
  let fake, runner = setup ~identities:0 () in
  ignore fake;
  match
    Ssh_agent.start ~runner ~paths:(paths ()) ~name:(name_exn "work")
      ~mode:Ssh_agent.Empty ()
  with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent -> (
      match Ssh_agent.loaded_identities ~runner agent with
      | Ok count -> Alcotest.(check int) "no identities" 0 count
      | Error e -> Alcotest.failf "list: %s" (Ade_error.to_string e))

let a_populated_agent_reports_its_identities () =
  let fake, runner = setup ~identities:1 () in
  ignore fake;
  match
    Ssh_agent.start ~runner ~paths:(paths ()) ~name:(name_exn "work")
      ~mode:(Ssh_agent.With_identity (identity_file ())) ()
  with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent -> (
      match Ssh_agent.loaded_identities ~runner agent with
      | Ok count -> Alcotest.(check int) "one identity" 1 count
      | Error e -> Alcotest.failf "list: %s" (Ade_error.to_string e))

(* The capability must not outlive the workbench that had it. *)
let stopping_the_agent_kills_it () =
  let fake, runner = setup () in
  match
    Ssh_agent.start ~runner ~paths:(paths ()) ~name:(name_exn "work")
      ~mode:Ssh_agent.Empty ()
  with
  | Error e -> Alcotest.failf "start: %s" (Ade_error.to_string e)
  | Ok agent -> (
      match Ssh_agent.stop ~runner agent with
      | Error e -> Alcotest.failf "stop: %s" (Ade_error.to_string e)
      | Ok () ->
          Alcotest.(check bool) "killed the agent" true
            (List.exists
               (fun r ->
                 Filename.basename r.Process_runner.executable = "ssh-agent"
                 && List.mem "-k" r.Process_runner.argv)
               fake.requests))

let failed_identity_read_releases_the_agent () =
  let fake, runner = setup () in
  let result = Ssh_agent.start ~runner ~paths:(paths ()) ~name:(name_exn "work")
      ~mode:(Ssh_agent.With_identity (Secret.file ~path:"/nonexistent/ade-key")) () in
  Alcotest.(check bool) "read failed" true (Result.is_error result);
  Alcotest.(check bool) "released" true
    (List.exists (fun r -> List.mem "-k" r.Process_runner.argv) fake.requests)

let failed_stop_is_reported () =
  let agent = Ssh_agent.of_record ~socket:"/nonexistent/ade.sock" ~pid:"4242" ~populated:true in
  let runner _ = Ok { Process_runner.status = 1; stdout = ""; stderr = "kill failed" } in
  Alcotest.(check bool) "stop failed" true (Result.is_error (Ssh_agent.stop ~runner agent))

let () =
  Alcotest.run "ssh_agent"
    [ ( "lifecycle",
        [ Alcotest.test_case "failed read releases" `Quick failed_identity_read_releases_the_agent;
          Alcotest.test_case "failed kill" `Quick failed_stop_is_reported;
          Alcotest.test_case "populated loads" `Quick a_populated_agent_loads_the_identity;
          Alcotest.test_case "socket" `Quick the_socket_is_read_from_the_agent;
          Alcotest.test_case "stop" `Quick stopping_the_agent_kills_it ] );
      ( "maintenance",
        [ Alcotest.test_case "stays empty" `Quick a_maintenance_agent_stays_empty;
          Alcotest.test_case "observably empty" `Quick
            an_empty_agent_reports_no_identities;
          Alcotest.test_case "populated counted" `Quick
            a_populated_agent_reports_its_identities ] );
      ( "secrecy",
        [ Alcotest.test_case "not in argv" `Quick the_key_never_reaches_argv;
          Alcotest.test_case "on stdin" `Quick the_key_travels_on_stdin ] )
    ]
