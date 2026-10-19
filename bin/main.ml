(* Cmdliner command tree only. All behavior lives in the library. *)

open Ade

let ( let* ) = Result.bind

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

let provider_of_string = function
  | "github" -> Ok Credential.Github
  | "kubernetes" -> Ok Credential.Kubernetes
  | "ssh" -> Ok Credential.Ssh
  | "datadog" -> Ok Credential.Datadog
  | "circleci" -> Ok Credential.Circleci
  | other ->
      Error
        (Ade_error.Operation_refused
           { operation = "credentials"; reason = "unknown provider " ^ Filename.quote other })

let credentials_status_command =
  let open Cmdliner in
  let run name =
    with_declaration name (fun _ declaration ->
        let name = Workbench_name.to_string (Declaration.name declaration) in
        (* Reports what ADE can actually do per provider. A provider that
           cannot be rotated says so rather than appearing healthy. *)
        List.iter
          (fun provider ->
            Printf.printf "%s\t%s\t%s\n" name
              (Credential.provider_to_string provider)
              (Provider.describe_rotation (Provider.rotation_of provider)))
          [ Credential.Github; Credential.Kubernetes; Credential.Ssh;
            Credential.Datadog; Credential.Circleci ];
        Ok ())
  in
  Cmd.v (Cmd.info "status" ~doc:"Show credential handling per provider")
    Term.(const run $ name_argument)

let credentials_rotate_command =
  let open Cmdliner in
  let due =
    Arg.(value & flag & info [ "due" ]
           ~doc:"Rotate only what is due, for every running workbench, then exit.")
  in
  let run name due =
    with_declaration name (fun lifecycle declaration ->
        let* status = Lifecycle.status lifecycle declaration in
        let running = status.Lifecycle.state = Smolvm.Running in
        let now = Unix.gettimeofday () in
        let workbench = Declaration.name declaration in
        let label = Workbench_name.to_string workbench in
        (* A stopped workbench needs no active generation: start, attach and
           exec install one before any dependent agent runs. *)
        let decision =
          Credential_schedule.decide ~now ~margin_seconds:300.0 ~running
            ~generation:None
        in
        match (decision, Declaration.github_credential declaration) with
        | Credential_schedule.Rotate, Some table ->
            let* config =
              Result.map_error
                (fun error ->
                  Ade_error.Operation_refused
                    { operation = "credentials rotate";
                      reason = Github_credential.describe_error error })
                (Github_credential.load_config table)
            in
            let smolvm =
              Smolvm.make ~executable:(smolvm_executable ()) ~runner:Process_runner.run
            in
            let* rotation =
              Credential_flow.rotate_github ~smolvm ~name:workbench ~config ~now
                ~previous:None ()
            in
            (* Secret-free by construction: provider, generation and outcome. *)
            print_endline
              (Credential.audit_line
                 {
                   Credential.provider = Credential.Github;
                   generation_number =
                     rotation.Credential_flow.generation.Credential.number;
                   expires_at =
                     rotation.Credential_flow.generation.Credential.expires_at;
                   outcome =
                     String.concat "+"
                       (List.map Credential_flow.describe_step
                          rotation.Credential_flow.steps);
                 });
            Ok ()
        | Credential_schedule.Rotate, None ->
            (* Due, but nothing declared to mint from. Saying so beats
               reporting success for work that did not happen. *)
            Printf.printf "%s\tdue, but no credentials are declared\n" label;
            Ok ()
        | decision, _ ->
            ignore due;
            Printf.printf "%s\t%s\n" label (Credential_schedule.describe decision);
            Ok ())
  in
  Cmd.v
    (Cmd.info "rotate" ~doc:"Rotate credentials that are due, then exit")
    Term.(const run $ name_argument $ due)

let credentials_revoke_command =
  let open Cmdliner in
  let provider_argument =
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PROVIDER")
  in
  let run name provider =
    with_declaration name (fun _ declaration ->
        let* provider = provider_of_string provider in
        let smolvm =
          Smolvm.make ~executable:(smolvm_executable ()) ~runner:Process_runner.run
        in
        let* () =
          Credential_installer.revoke ~smolvm ~name:(Declaration.name declaration) ~provider
        in
        (* Secret-free by construction: the provider and outcome, never a value. *)
        print_endline
          (Credential.audit_line
             {
               Credential.provider;
               generation_number = 0;
               expires_at = 0.0;
               outcome = "revoked";
             });
        Ok ())
  in
  Cmd.v
    (Cmd.info "revoke" ~doc:"Remove the active generation from the workbench")
    Term.(const run $ name_argument $ provider_argument)

let credentials_command =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "credentials" ~doc:"Inspect and rotate workbench credentials")
    [ credentials_status_command; credentials_rotate_command; credentials_revoke_command ]

let commands =
  [
    simple_command "create" "Create the workbench from its declaration" Lifecycle.create;
    simple_command "start" "Start the workbench" Lifecycle.start;
    simple_command "stop" "Stop the workbench" Lifecycle.stop;
    simple_command "restart" "Restart the workbench" Lifecycle.restart;
    attach_command;
    exec_command;
    status_command;
    rm_command;
    credentials_command;
  ]

let () =
  let open Cmdliner in
  let info = Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs" in
  let default = Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ())) in
  exit (Cmd.eval' (Cmd.group info ~default commands))
