(* Cmdliner command tree only. All behavior lives in the library. *)

open Ade

let ( let* ) = Result.bind

let version = "ade 0.1.0"

let exit_of_error error =
  prerr_endline ("ade: " ^ Ade_error.to_string error);
  1

(* Process_runner needs an absolute path, so a bare "smolvm" is searched for on
   PATH here. ADE_SMOLVM_BIN overrides for tests. When nothing is found the
   bare name is kept, so the error names what the user has to install. *)
let smolvm_executable () =
  match Sys.getenv_opt "ADE_SMOLVM_BIN" with
  | Some path -> path
  | None ->
      let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
      let candidates =
        List.filter_map
          (fun dir -> if dir = "" then None else Some (Filename.concat dir "smolvm"))
          (String.split_on_char ':' path)
      in
      Option.value (List.find_opt Sys.file_exists candidates) ~default:"smolvm"

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

let report label = function
  | Lifecycle.Converged -> print_endline (label ^ ": already satisfied")
  | Lifecycle.Changed -> print_endline (label ^ ": done")

let name_argument =
  let open Cmdliner in
  Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Workbench name")

let simple_command term_name doc action =
  let open Cmdliner in
  let run name =
    with_declaration name (fun lifecycle declaration ->
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
  let run name command =
    with_declaration name (fun lifecycle declaration ->
        Result.map
          (fun output ->
            print_string output.Process_runner.stdout;
            prerr_string output.Process_runner.stderr)
          (Lifecycle.exec lifecycle declaration command))
  in
  Cmd.v
    (Cmd.info "exec" ~doc:"Run one command inside the workbench")
    Term.(const run $ name_argument $ command_argument)

let provision_command =
  simple_command "provision" "Re-run the declared provisioning script (workbench must be stopped)"
    Lifecycle.provision

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

let commands =
  [
    simple_command "create" "Create the workbench from its declaration" Lifecycle.create;
    simple_command "start" "Start the workbench" Lifecycle.start;
    simple_command "stop" "Stop the workbench" Lifecycle.stop;
    simple_command "restart" "Restart the workbench" Lifecycle.restart;
    attach_command;
    exec_command;
    status_command;
    provision_command;
    rm_command;
  ]

let () =
  let open Cmdliner in
  let info = Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs" in
  let default = Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ())) in
  exit (Cmd.eval' (Cmd.group info ~default commands))
