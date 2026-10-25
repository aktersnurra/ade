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

(* Declarations are policy, so they come from one fixed place in the user's
   config, never from the current directory: running ade inside a checkout
   that ships its own workbenches/ must not hand that checkout the policy. *)
let declarations_dir () =
  match Sys.getenv_opt "ADE_WORKBENCHES_DIR" with
  | Some dir when dir <> "" -> dir
  | Some _ | None ->
      let config =
        match Sys.getenv_opt "XDG_CONFIG_HOME" with
        | Some base when base <> "" -> base
        | Some _ | None ->
            Filename.concat (Option.value (Sys.getenv_opt "HOME") ~default:"/") ".config"
      in
      Filename.concat (Filename.concat config "ade") "workbenches"

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
  (* Every secret reference the declaration would read at start. *)
  let references declaration =
    let ssh =
      match Declaration.ssh declaration with
      | Declaration.Disabled -> []
      | Declaration.Dedicated_agent { key_ref } -> [ ("ssh key", Secret.of_reference key_ref) ]
    in
    let github =
      match Declaration.github_credential declaration with
      | None -> []
      | Some table -> (
          match Github_credential.load_config table with
          | Ok config -> [ ("github key", Ok config.Github_credential.private_key) ]
          | Error error -> [ ("github key", Error (Github_credential.describe_error error)) ])
    in
    let anthropic =
      match Declaration.anthropic_api_key_ref declaration with
      | None -> []
      | Some reference -> [ ("anthropic", Secret.of_reference reference) ]
    in
    let classifier =
      match Declaration.network declaration with
      | Declaration.Proxied { classifier = Some { api_key_ref; _ }; _ } ->
          [ ("classifier", Secret.of_reference api_key_ref) ]
      | _ -> []
    in
    ssh @ github @ anthropic @ classifier
  in
  let name =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME"
           ~doc:"Also check this workbench's declaration and that its secrets are readable.")
  in
  let run name =
    let host =
      Doctor.run ~runner:Process_runner.run
        ~find_executable:Process_runner.find_executable
        ~smolvm:(smolvm_executable ()) ~kvm_usable
    in
    let workbench =
      match name with
      | None -> []
      | Some name -> (
          match load_declaration name with
          | Error error ->
              [ { Doctor.name = "declaration"; verdict = Doctor.Fail;
                  detail = Ade_error.to_string error } ]
          | Ok declaration ->
              { Doctor.name = "declaration"; verdict = Doctor.Pass;
                detail = Declaration.path declaration }
              :: Doctor.secret_checks
                   ~read:(fun secret -> Secret.with_value secret ~f:(fun _ -> Ok ()))
                   (references declaration))
    in
    let checks = host @ workbench in
    List.iter (fun check -> print_endline (Doctor.render check)) checks;
    if Doctor.healthy checks then 0 else 1
  in
  Cmd.v
    (Cmd.info "doctor" ~doc:"Check the host, and optionally a workbench, have what ADE needs")
    Term.(const run $ name)

let clock time =
  let tm = Unix.localtime time in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let net_command =
  let open Cmdliner in
  let with_net name action =
    match load_declaration name with
    | Error error -> exit_of_error error
    | Ok declaration -> (
        match action (State_paths.make ()) declaration with
        | Ok () -> 0
        | Error error -> exit_of_error error)
  in
  let pending =
    let run name =
      with_net name (fun paths declaration ->
          Result.map
            (function
              | [] -> print_endline "no blocked requests"
              | entries ->
                  List.iter
                    (fun (entry : Egress.pending) ->
                      Printf.printf "%s  (%d attempt%s, last %s)\n"
                        (Egress.render_target entry.target) entry.attempts
                        (if entry.attempts = 1 then "" else "s")
                        (clock entry.last_attempt);
                      (match entry.verdict with
                       | Some (Egress.Deny, reason) -> Printf.printf "  denied by the classifier: %s\n" reason
                       | Some (_, "") | None -> ()
                       | Some (_, reason) -> Printf.printf "  needs you: %s\n" reason);
                      Printf.printf "  allow with: ade net allow %s %s [--always]\n" name
                        (Egress.render_allow_argument entry.target))
                    entries)
            (Net.pending ~paths declaration))
    in
    Cmd.v
      (Cmd.info "pending" ~doc:"List requests the proxy refused that are still not allowed")
      Term.(const run $ name_argument)
  in
  let allow =
    let host =
      Arg.(required & pos 1 (some string) None & info [] ~docv:"HOST"
             ~doc:"HOST (ports 443 and 80), HOST:PORT, or *.SUFFIX.")
    in
    let always =
      Arg.(value & flag & info [ "always" ]
             ~doc:"Keep allowing it: add it to NAME.allow next to the declaration. Without this \
                   it is allowed until the workbench next starts.")
    in
    let run name host always =
      with_net name (fun paths declaration ->
          let scope = if always then Net.Always else Net.Session in
          Result.map
            (fun file ->
              if always then Printf.printf "allowed %s (added to %s)\n" host file
              else Printf.printf "allowed %s until %s next starts\n" host name)
            (Net.allow ~paths declaration ~host ~scope))
    in
    Cmd.v
      (Cmd.info "allow" ~doc:"Allow a host through the workbench's egress proxy")
      Term.(const run $ name_argument $ host $ always)
  in
  let revoke =
    let host =
      Arg.(required & pos 1 (some string) None & info [] ~docv:"HOST"
             ~doc:"The host to take back.")
    in
    let run name host =
      with_net name (fun paths declaration ->
          Result.map
            (fun still_declared ->
              Printf.printf "revoked %s until %s next starts\n" host name;
              if still_declared then
                Printf.printf
                  "note: %s is listed in %s or %s, so it stays allowed; remove it there\n" host
                  (Declaration.path declaration) (Net.allow_file declaration))
            (Net.revoke ~paths declaration ~host))
    in
    Cmd.v
      (Cmd.info "revoke"
         ~doc:"Take back a host allowed this session, by you or the classifier")
      Term.(const run $ name_argument $ host)
  in
  let log =
    let count =
      Arg.(value & opt int 50 & info [ "n" ] ~docv:"N" ~doc:"Show the last N entries.")
    in
    let run name count =
      with_net name (fun paths declaration ->
          Result.map
            (fun events ->
              let skip = max 0 (List.length events - count) in
              List.iteri
                (fun i event ->
                  if i >= skip then
                    match event with
                    | Egress.Decision { time; target; allowed } ->
                        Printf.printf "%s  %s  %s\n" (clock time)
                          (if allowed then "allow" else "BLOCK")
                          (Egress.render_target target)
                    | Egress.Classified { time; host; verdict; reason } ->
                        Printf.printf "%s  %-5s  %s  %s\n" (clock time)
                          (match verdict with
                           | Egress.Allow -> "auto"
                           | Egress.Deny -> "deny"
                           | Egress.Ask | Egress.Unavailable -> "ask")
                          host reason)
                events)
            (Net.log ~paths declaration))
    in
    Cmd.v
      (Cmd.info "log" ~doc:"Show the egress proxy's decisions and classifications")
      Term.(const run $ name_argument $ count)
  in
  let serve =
    let path =
      Arg.(required & pos 0 (some file) None & info [] ~docv:"DECLARATION")
    in
    let run path =
      match Net.serve ~paths:(State_paths.make ()) ~declaration_path:path with
      | Ok () -> 0
      | Error error -> exit_of_error error
    in
    Cmd.v
      (Cmd.info "serve"
         ~doc:"Run a workbench's egress proxy in the foreground. ade start runs this itself.")
      Term.(const run $ path)
  in
  Cmd.group
    (Cmd.info "net" ~doc:"Egress for proxied workbenches: blocked requests and approvals")
    [ pending; allow; revoke; log; serve ]

let commands =
  [
    doctor_command;
    simple_command "create" "Create the workbench from its declaration" Lifecycle.create;
    simple_command ~warn:true "start" "Start the workbench" Lifecycle.start;
    simple_command "stop" "Stop the workbench" Lifecycle.stop;
    simple_command ~warn:true "restart" "Restart the workbench" Lifecycle.restart;
    simple_command "refresh" "Mint a fresh GitHub token into the running workbench"
      Lifecycle.refresh;
    attach_command;
    exec_command;
    status_command;
    provision_command;
    pull_command;
    net_command;
    rm_command;
  ]

let () =
  let open Cmdliner in
  let info = Cmd.info "ade" ~version ~doc:"Manage local agent workbench VMs" in
  let default = Term.(ret (const (fun () -> `Help (`Pager, None)) $ const ())) in
  exit (Cmd.eval' (Cmd.group info ~default commands))
