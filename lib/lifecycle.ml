type outcome = Converged | Changed

type t = { smolvm : Smolvm.t; paths : State_paths.t; services : Boot.services }

let make ~services ~smolvm ~paths = { smolvm; paths; services }

let ( let* ) = Result.bind

type settled_state = Absent | Created | Stopped | Running

(* A successful observation refines the state available to lifecycle commands. *)
let settle : Smolvm.state -> (settled_state, Ade_error.t) result = function
  | Smolvm.Booting -> Error (Ade_error.Operation_refused
      { operation = "transition workbench"; reason = "machine is booting; retry when settled" })
  | Smolvm.Stopping -> Error (Ade_error.Operation_refused
      { operation = "transition workbench"; reason = "machine is stopping; retry when settled" })
  | Smolvm.Failed reason -> Error (Ade_error.Operation_refused
      { operation = "transition workbench"; reason })
  | Smolvm.Absent -> Ok Absent
  | Smolvm.Created -> Ok Created
  | Smolvm.Stopped -> Ok Stopped
  | Smolvm.Running -> Ok Running

let observe_settled t name =
  let* state = Smolvm.state t.smolvm name in
  settle state

type drift = Not_created | Matches | Unknown of string | Drifted of string list

let describe_drift = function
  | Not_created | Matches -> None
  | Unknown reason -> Some ("creation state unknown: " ^ reason)
  | Drifted groups -> Some (Printf.sprintf
      "%s changed since the machine was created; these apply only at creation, so they take effect after ade rm and ade create"
      (String.concat ", " groups))

let drift_of t declaration state =
  match state with
  | Smolvm.Absent -> Not_created
  | _ -> (
      match Creation_manifest.load ~paths:t.paths (Declaration.name declaration) with
      | Error error -> Unknown (Ade_error.to_string error)
      | Ok None -> Unknown "no creation manifest; inspect the machine before recreating it"
      | Ok (Some recorded) -> (
          match Host_mount.for_declaration ~paths:t.paths declaration with
          | Error error -> Unknown (Ade_error.to_string error)
          | Ok mounts ->
              let current = Creation_manifest.make declaration mounts in
              match Creation_manifest.changes ~recorded ~current with
              | [] -> Matches
              | groups -> Drifted groups))

(* Mounts are resolved immediately before creation, on the host that will run
   the machine, so a symlink swapped after the declaration was written is
   still caught. *)
let create_machine t declaration =
  let* mounts = Host_mount.for_declaration ~paths:t.paths declaration in
  let manifest = Creation_manifest.make declaration mounts in
  let name = Declaration.name declaration in
  let* () = State_paths.ensure_dir (State_paths.inbox_dir t.paths name) in
  let* () = State_paths.ensure_dir (State_paths.outbox_dir t.paths name) in
  let* () = Smolvm.create t.smolvm declaration ~mounts in
  Creation_manifest.save ~paths:t.paths manifest

let with_lock t declaration action =
  Workbench_lock.with_lock t.paths (Declaration.name declaration) action

let halt t name = Boot.stop ~services:t.services ~smolvm:t.smolvm ~paths:t.paths name

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error reason ->
    Error (Ade_error.Declaration_invalid { path; reason })

(* A command run directly reads no shell profile, so a proxied guest's proxy
   is passed to it explicitly. *)
let with_proxy_environment declaration command =
  match Net.environment declaration with
  | [] -> command
  | environment -> ("env" :: List.map (fun (key, value) -> key ^ "=" ^ value) environment) @ command

(* Maintenance boots hold no identity or credentials. Always attempt shutdown;
   if it also fails, report both causes rather than claiming rollback completed. *)
let run_provision t declaration script =
  let name = Declaration.name declaration in
  let* source = read_file script in
  let* () =
    Boot.start ~services:t.services ~smolvm:t.smolvm ~paths:t.paths
      ~purpose:Boot.Maintenance declaration
  in
  let ran =
    (* bash -s reads no profile, so a proxied guest is told its proxy here. *)
    let argv = with_proxy_environment declaration [ "bash"; "-s" ] in
    match Smolvm.exec_with_stdin t.smolvm name argv ~stdin:source with
    | Error _ as error -> error
    | Ok { Process_runner.status = 0; _ } -> Ok ()
    | Ok { Process_runner.status; stderr; _ } ->
        Error (Ade_error.Runtime_failed { argv = [ "provision"; script ]; status; stderr })
  in
  let stopped = halt t name in
  match ran, stopped with
  | Ok (), result -> result
  | Error cause, Ok () -> Error cause
  | Error cause, Error cleanup -> Error (Ade_error.Rollback_failed { cause; cleanup = [ cleanup ] })

(* A machine is only useful once provisioned, so creation and provisioning are
   one step; a failed script leaves the machine created and stopped for
   [ade provision] to retry. *)
let create_and_provision t declaration =
  let* () = create_machine t declaration in
  match Declaration.provision declaration with
  | None -> Ok ()
  | Some script -> run_provision t declaration script

let create t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* observed = Smolvm.state t.smolvm name in
      let* state = settle observed in
      match state with
      | Absent ->
          let* () = create_and_provision t declaration in
          Ok Changed
      | Created | Stopped | Running -> (
          (* Creating an existing machine is a no-op when it matches, and a
             drift report otherwise. It never recreates the machine, because
             that would destroy the workspace. *)
          let drift = drift_of t declaration observed in
          match describe_drift drift with
          | None -> Ok Converged
          | Some reason ->
              Error
                (Ade_error.Declaration_invalid
                   { path = Workbench_name.to_string name; reason })))

(* Starting is expressed as "ensure running", so a running machine converges as
   a no-op after its state is confirmed. *)
let boot t declaration =
  Boot.start ~services:t.services ~smolvm:t.smolvm ~paths:t.paths
    ~purpose:Boot.Work declaration

let ensure_running t declaration =
  let name = Declaration.name declaration in
  let* state = observe_settled t name in
  match state with
  | Running ->
      (* A running machine whose proxy died has no network at all. *)
      let* () = t.services.ensure_proxy declaration in
      Ok Converged
  | Created | Stopped ->
      let* () = boot t declaration in
      Ok Changed
  | Absent ->
      let* () = create_and_provision t declaration in
      let* () = boot t declaration in
      Ok Changed

let start t declaration = with_lock t declaration (fun () -> ensure_running t declaration)

let stop t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = observe_settled t name in
      match state with
      | Stopped | Created | Absent ->
          (* The machine may have stopped without ADE; its agent must not
             outlive it. *)
          let* () = Boot.release ~services:t.services ~paths:t.paths name in
          Ok Converged
      | Running ->
          let* () = halt t name in
          Ok Changed)

let restart t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = observe_settled t name in
      let* () =
        match state with
        | Running -> halt t name
        | Absent | Created | Stopped -> Ok ()
      in
      let* _ = ensure_running t declaration in
      Ok Changed)

let provision t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      match Declaration.provision declaration with
      | None ->
          Error
            (Ade_error.Operation_refused
               { operation = "provision"; reason = "the declaration names no provision script" })
      | Some script -> (
          let* state = observe_settled t name in
          match state with
          | Running ->
              Error
                (Ade_error.Operation_refused
                   { operation = "provision";
                     reason = "the workbench is running; stop it first" })
          | Absent ->
              let* () = create_and_provision t declaration in
              Ok Changed
          | Created | Stopped ->
              let* () = run_provision t declaration script in
              Ok Changed))

(* Tokens last an hour and are minted at start; this mints the next
   generation into a running workbench without restarting the agents, and
   hands it the host's new commits. A stopped workbench has nothing to
   refresh: its next start does both anew. *)
let refresh t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let github = Declaration.github_credential declaration <> None in
      let* state = observe_settled t name in
      match state with
      | Running when github || Declaration.repos declaration <> [] ->
          let* () = t.services.sync_repos ~smolvm:t.smolvm declaration in
          let* () =
            if github then t.services.install_credentials ~smolvm:t.smolvm ~name declaration
            else Ok ()
          in
          Ok Changed
      | Running | Created | Stopped | Absent -> Ok Converged)

let pull t declaration ~repo =
  with_lock t declaration (fun () ->
      let* _ = ensure_running t declaration in
      match Process_runner.find_executable "git" with
      | None -> Error (Ade_error.Runtime_unavailable { executable = "git" })
      | Some git -> Pull.run ~smolvm:t.smolvm ~runner:Process_runner.run ~git
          ~paths:t.paths ~name:(Declaration.name declaration) ~repo)

let remove t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = observe_settled t name in
      let* () = match state with Running -> halt t name | Absent | Created | Stopped -> Ok () in
      let* () =
        match state with Absent -> Ok () | Created | Stopped | Running -> Smolvm.delete t.smolvm name
      in
      let* () = Boot.release ~services:t.services ~paths:t.paths name in
      let dir = State_paths.workbench_dir t.paths name in
      match Bos.OS.Dir.delete ~recurse:true (Fpath.v dir) with
      | Error (`Msg reason) ->
          Error (Ade_error.Operation_refused { operation = "rm"; reason })
      | Ok () -> Ok (if state = Absent then Converged else Changed))

let attach t declaration ~command =
  (* The machine is brought up under the lock, but the lock is released before
     attaching: an interactive session may last hours and must not block every
     other operation on the workbench. *)
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
  (* With Herdr enabled, a bare attach lands in Herdr, which connects to the
     guest's server or spawns it. Agents are started by the user from there.
     It runs from a login shell: Herdr and the agents live in ~/.local/bin,
     which only the profile puts on PATH, and the panes inherit it. *)
  let command =
    match command with
    | [] when Declaration.herdr_enabled declaration -> [ "sh"; "-lc"; "exec herdr" ]
    | command -> command
  in
  Smolvm.attach t.smolvm (Declaration.name declaration) ~command

let exec t declaration command =
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
  Smolvm.exec t.smolvm (Declaration.name declaration) (with_proxy_environment declaration command)

type status = { name : string; state : Smolvm.state; drift : drift }

let status t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  let drift = drift_of t declaration state in
  Ok { name = Workbench_name.to_string name; state; drift }
