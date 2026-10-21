(* Cmdliner command tree only. All behavior lives in the library. *)

open Ade

let ( let* ) = Result.bind

let version = "ade 0.1.0"

let exit_of_error error =
  prerr_endline ("ade: " ^ Ade_error.to_string error);
  1

(* ADE_SMOLVM_BIN overrides for tests. Otherwise smolvm is found on PATH; when
   it is not, the bare name is kept so the error names what to install. *)
let smolvm_executable () =
  match Sys.getenv_opt "ADE_SMOLVM_BIN" with
  | Some path -> path
  | None -> Option.value (Process_runner.find_executable "smolvm") ~default:"smolvm"

let declarations_dir () =
  match Sys.getenv_opt "ADE_WORKBENCHES_DIR" with
  | Some dir -> dir
  | None -> "workbenches"

let load_declaration name =
  Declaration.load (Filename.concat (declarations_dir ()) (name ^ ".toml"))

let lifecycle () =
  let smolvm =
    Smolvm.make ~executable:(smolvm_executable ()) ~runner:Process_runner.run
  in
  let paths = State_paths.make () in
  Lifecycle.make ~services:(Boot.default_services ~paths) ~smolvm ~paths

let with_declaration name action =
  match load_declaration name with
  | Error error -> exit_of_error error
  | Ok declaration -> (
      match action (lifecycle ()) declaration with
      | Ok () -> 0
      | Error error -> exit_of_error error)

(* Commands that use a machine as it stands warn when it no longer matches its
   declaration: a mount removed from the file is still mounted, and the user
   should hear that before the agents run, not from ade status later. *)
let warn_if_drifted lifecycle declaration =
  match Lifecycle.status lifecycle declaration with
  | Ok { Lifecycle.drift = Some reason; name; _ } ->
      prerr_endline (Printf.sprintf "ade: warning: %s: %s" name reason)
  | Ok _ | Error _ -> ()

let report label = function
  | Lifecycle.Converged -> print_endline (label ^ ": already satisfied")
  | Lifecycle.Changed -> print_endline (label ^ ": done")

let name_argument =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Workbench name")

let simple_command ?(warn = false) term_name doc action =
  let open Cmdliner in
  let run name =
    with_declaration name (fun lifecycle declaration ->
        if warn then warn_if_drifted lifecycle declaration;
        Result.map (report term_name) (action lifecycle declaration))
  in
  Cmd.v (Cmd.info term_name ~doc) Term.(const run $ name_argument)

let render_state = function
  | Smolvm.Absent -> "absent"
  | Smolvm.Created -> "created"
  | Smolvm.Stopped -> "stopped"
  | Smolvm.Running -> "running"

let status_command =
  let open Cmdliner in
  let run name =
    with_declaration name (fun lifecycle declaration ->
        Result.map
          (fun status ->
            Printf.printf "%s\t%s\n" status.Lifecycle.name
              (render_state status.Lifecycle.state);
            match status.Lifecycle.drift with
            | Some reason -> Printf.printf "drift\t%s\n" reason
            | None -> ())
          (Lifecycle.status lifecycle declaration))
  in
  Cmd.v (Cmd.info "status" ~doc:"Show a workbench's observed state") 
    Term.(const run $ name_argument)

let attach_command =
  let open Cmdliner in
  let command_argument =
    Arg.(value & pos_right 0 string [] & info [] ~docv:"COMMAND")
  in
  let run name command =
    with_declaration name (fun lifecycle declaration ->
        warn_if_drifted lifecycle declaration;
        Lifecycle.attach lifecycle declaration ~command)
  in
  Cmd.v
    (Cmd.info "attach" ~doc:"Start if needed, then attach to the workbench")
    Term.(const run $ name_argument $ command_argument)

let exec_command =
  let open Cmdliner in
  let command_argument =
    Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"COMMAND")
  in
  (* The guest command's status is the command's status, so scripts and
     agents can tell whether what they ran worked. *)
  let run name command =
    match load_declaration name with
    | Error error -> exit_of_error error
    | Ok declaration -> (
        let lifecycle = lifecycle () in
        warn_if_drifted lifecycle declaration;
        match Lifecycle.exec lifecycle declaration command with
        | Error error -> exit_of_error error
        | Ok output ->
            print_string output.Process_runner.stdout;
            prerr_string output.Process_runner.stderr;
            output.Process_runner.status)
  in
  Cmd.v
    (Cmd.info "exec" ~doc:"Run one command inside the workbench")
    Term.(const run $ name_argument $ command_argument)

let provision_command =
  simple_command "provision" "Re-run the declared provisioning script (workbench must be stopped)"
    Lifecycle.provision

let pull_command =
  let open Cmdliner in
  let repo =
    Arg.(value & pos 1 (some string) None & info [] ~docv:"REPO"
           ~doc:"Only this clone mount; default is every one.")
  in
  let run name repo =
    with_declaration name (fun lifecycle declaration ->
        warn_if_drifted lifecycle declaration;
        Result.map
          (List.iter (fun repo ->
               Printf.printf "pull: %s -> refs/remotes/agents/*\n" repo))
          (Lifecycle.pull lifecycle declaration ~repo))
  in
  Cmd.v
    (Cmd.info "pull"
       ~doc:"Bring the agents' branches back from clone mounts as agents/*")
    Term.(const run $ name_argument $ repo)

let rm_command =
  let open Cmdliner in
  let yes =
    Arg.(value & flag & info [ "yes" ]
           ~doc:"Confirm deleting the machine and everything in its workspace.")
  in
  let run name yes =
    if not yes then (
      prerr_endline "ade: rm deletes the machine and its workspace; pass --yes to confirm";
      1)
    else
      with_declaration name (fun lifecycle declaration ->
          Result.map (report "rm") (Lifecycle.remove lifecycle declaration))
  in
  Cmd.v
    (Cmd.info "rm" ~doc:"Delete the workbench machine and its state")
    Term.(const run $ name_argument $ yes)

let doctor_command =
  let open Cmdliner in
  let kvm_usable () =
    try Unix.access "/dev/kvm" [ Unix.R_OK; Unix.W_OK ]; true
    with Unix.Unix_error _ -> false
  in
  let run () =
    let checks =
      Doctor.run ~runner:Process_runner.run
        ~find_executable:Process_runner.find_executable
        ~smolvm:(smolvm_executable ()) ~kvm_usable
    in
    List.iter (fun check -> print_endline (Doctor.render check)) checks;
    if Doctor.healthy checks then 0 else 1
  in
  Cmd.v
    (Cmd.info "doctor" ~doc:"Check the host has what ADE needs")
    Term.(const run $ const ())

let commands =
  [
    doctor_command;
    simple_command "create" "Create the workbench from its declaration" Lifecycle.create;
    simple_command ~warn:true "start" "Start the workbench" Lifecycle.start;
    simple_command "stop" "Stop the workbench" Lifecycle.stop;
    simple_command ~warn:true "restart" "Restart the workbench" Lifecycle.restart;
    attach_command;
    exec_command;
    status_command;
    provision_command;
    pull_command;
    rm_command;
  ]

let () =
  let open Cmdliner in
  let info = Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs" in
  let default = Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ())) in
  exit (Cmd.eval' (Cmd.group info ~default commands))
