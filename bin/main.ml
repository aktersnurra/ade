(* Cmdliner command tree only. All behavior lives in the library. *)

open Ade

let version = "ade 0.1.0"

let exit_of_error error =
  prerr_endline ("ade: " ^ Ade_error.to_string error);
  1

(* The runtime binary is resolved from the managed runtime root, with an
   override for tests and qualification so no test ever depends on a runtime
   installed for real use. *)
let smolvm_executable () =
  match Sys.getenv_opt "ADE_SMOLVM_BIN" with
  | Some path -> path
  | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home ->
          List.fold_left Filename.concat home
            [ ".local"; "share"; "ade"; "runtime"; "smolvm-1.13.1"; "bin"; "smolvm" ]
      | None -> "smolvm")

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
  Lifecycle.make ~smolvm ~paths:(State_paths.make ())

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

let maintenance () =
  Smolvm.make ~executable:(smolvm_executable ()) ~runner:Process_runner.run

let report_outcome label (outcome : Maintenance.outcome) =
  Printf.printf "%s: %s\n" label (String.concat ", " outcome.Maintenance.performed);
  match outcome.Maintenance.manifest_digest with
  | Some digest -> Printf.printf "workspace manifest %s\n" digest
  | None -> ()

let backup_command =
  let open Cmdliner in
  let destination =
    Arg.(required & pos 1 (some string) None & info [] ~docv:"DESTINATION")
  in
  let run name destination =
    with_declaration name (fun _ declaration ->
        Result.map (report_outcome "backup")
          (Maintenance.backup ~smolvm:(maintenance ()) ~paths:(State_paths.make ())
             ~declaration ~destination))
  in
  Cmd.v
    (Cmd.info "backup" ~doc:"Export and validate the workspace only")
    Term.(const run $ name_argument $ destination)

let restore_command =
  let open Cmdliner in
  let archive = Arg.(required & pos 1 (some string) None & info [] ~docv:"ARCHIVE") in
  let replace =
    Arg.(value & flag & info [ "replace-workspace" ]
           ~doc:"Overwrite the target workspace. Required: ADE never merges a \
                 backup into a nonempty workspace.")
  in
  let as_new =
    Arg.(value & opt (some string) None & info [ "as" ] ~docv:"NAME"
           ~doc:"Restore into a new machine under this name.")
  in
  let run name archive replace as_new =
    match (replace, as_new) with
    | false, None ->
        prerr_endline
          "ade: choose --replace-workspace or --as NAME; a restore never merges";
        1
    | true, Some _ ->
        prerr_endline "ade: --replace-workspace and --as are mutually exclusive";
        1
    | _ ->
        with_declaration name (fun _ declaration ->
            let mode =
              match as_new with
              | Some target -> (
                  match Workbench_name.of_string target with
                  | Ok target -> Ok (Maintenance.Into_new_machine target)
                  | Error reason ->
                      Error
                        (Ade_error.Workbench_name_invalid
                           { value = target; reason = Workbench_name.error_reason reason }))
              | None -> Ok Maintenance.Replace_workspace
            in
            Result.bind mode (fun mode ->
                Result.map (report_outcome "restore")
                  (Maintenance.restore ~smolvm:(maintenance ())
                     ~paths:(State_paths.make ()) ~declaration ~archive ~mode)))
  in
  Cmd.v
    (Cmd.info "restore" ~doc:"Restore a validated workspace backup")
    Term.(const run $ name_argument $ archive $ replace $ as_new)

let reimage_command =
  let open Cmdliner in
  let force =
    Arg.(value & flag & info [ "force-quiesce" ]
           ~doc:"Proceed even though agents are running, losing their in-flight work.")
  in
  let run name force_quiesce =
    with_declaration name (fun _ declaration ->
        Result.map (report_outcome "reimage")
          (Maintenance.reimage ~smolvm:(maintenance ()) ~paths:(State_paths.make ())
             ~declaration ~force_quiesce))
  in
  Cmd.v
    (Cmd.info "reimage"
       ~doc:"Rebuild trusted guest state, preserving validated workspace data")
    Term.(const run $ name_argument $ force)

let pack_command =
  let open Cmdliner in
  let output = Arg.(required & pos 1 (some string) None & info [] ~docv:"OUTPUT") in
  let run name output =
    with_declaration name (fun _ declaration ->
        Result.map
          (fun outcome ->
            report_outcome "pack" outcome;
            prerr_endline
              "ade: a pack may contain credentials, login state and caches; treat it as secret-bearing")
          (Maintenance.pack ~smolvm:(maintenance ()) ~declaration ~output))
  in
  Cmd.v
    (Cmd.info "pack" ~doc:"Create a full machine artifact from a stopped workbench")
    Term.(const run $ name_argument $ output)

let destroy_command =
  let open Cmdliner in
  let backup_first =
    Arg.(value & flag & info [ "backup-first" ] ~doc:"Back up the workspace, then destroy.")
  in
  let no_backup =
    Arg.(value & flag & info [ "no-backup" ] ~doc:"Destroy without creating a backup.")
  in
  let confirm =
    Arg.(value & opt (some string) None
         & info [ "confirm-destroy-workspace" ] ~docv:"NAME")
  in
  let destination =
    Arg.(value & opt (some string) None & info [ "backup-to" ] ~docv:"DIRECTORY")
  in
  let run name backup_first no_backup confirmation destination =
    if backup_first = no_backup then (
      (* ADE never infers safety from a recent backup: it cannot know whether
         the workspace changed afterward. *)
      prerr_endline "ade: choose exactly one of --backup-first or --no-backup";
      1)
    else
      with_declaration name (fun _ declaration ->
          let choice =
            if backup_first then Destroy.Backup_first else Destroy.No_backup
          in
          let request =
            { Destroy.name = Declaration.name declaration; choice; confirmation }
          in
          Result.map (report_outcome "destroy")
            (Maintenance.destroy ~smolvm:(maintenance ()) ~paths:(State_paths.make ())
               ~declaration ~request ~backup_destination:destination))
  in
  Cmd.v
    (Cmd.info "destroy" ~doc:"Remove the machine and all machine-owned state")
    Term.(const run $ name_argument $ backup_first $ no_backup $ confirm $ destination)

let commands =
  [
    simple_command "create" "Create the workbench from its declaration" Lifecycle.create;
    simple_command "start" "Start the workbench" Lifecycle.start;
    simple_command "stop" "Stop the workbench" Lifecycle.stop;
    simple_command "restart" "Restart the workbench" Lifecycle.restart;
    attach_command;
    exec_command;
    status_command;
    backup_command;
    restore_command;
    reimage_command;
    pack_command;
    destroy_command;
  ]

let () =
  let open Cmdliner in
  let info = Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs" in
  let default = Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ())) in
  exit (Cmd.eval' (Cmd.group info ~default commands))
