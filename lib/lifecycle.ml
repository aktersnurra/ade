type outcome = Converged | Changed

type t = { smolvm : Smolvm.t; paths : State_paths.t; services : Boot.services }

let make ~services ~smolvm ~paths = { smolvm; paths; services }

let ( let* ) = Result.bind

(* The record is one "group<TAB>value" line per pair of the creation shape.
   It names host paths but holds nothing secret. *)
let render_shape shape =
  String.concat "" (List.map (fun (group, value) -> group ^ "\t" ^ value ^ "\n") shape)

let parse_shape text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
         match String.index_opt line '\t' with
         | Some tab -> Some (String.sub line 0 tab, String.sub line (tab + 1) (String.length line - tab - 1))
         | None -> None)

let record_creation t declaration =
  let name = Declaration.name declaration in
  let* () = State_paths.ensure_dir (State_paths.workbench_dir t.paths name) in
  let path = State_paths.created_file t.paths name in
  (* Bos writes through a temporary file and renames, so a crash never leaves a
     half-written record that would report false drift. *)
  match
    Bos.OS.File.write ~mode:0o600 (Fpath.v path) (render_shape (Declaration.creation_shape declaration))
  with
  | Ok () -> Ok ()
  | Error (`Msg reason) -> Error (Ade_error.Operation_refused { operation = "record creation"; reason })

(* Drift is reported, never silently repaired: ADE does not mutate a machine to
   resolve a mismatch with the declaration, because what differs (mounts,
   resources, network) is fixed at creation and changing it means recreating
   the machine, which destroys its workspace. A machine with no record, created
   before records existed or outside ADE, is not compared. *)
let drift_of t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  match state with
  | Smolvm.Absent -> Ok None
  | _ -> (
      match In_channel.with_open_bin (State_paths.created_file t.paths name) In_channel.input_all with
      | exception Sys_error _ -> Ok None
      | text ->
          let recorded = parse_shape text in
          let current = Declaration.creation_shape declaration in
          let values group shape =
            List.sort String.compare
              (List.filter_map (fun (g, v) -> if g = group then Some v else None) shape)
          in
          let changed =
            List.filter
              (fun group -> values group recorded <> values group current)
              [ "image"; "resources"; "network"; "ssh"; "mounts" ]
          in
          if changed = [] then Ok None
          else
            Ok
              (Some
                 (Printf.sprintf
                    "%s changed since the machine was created; these apply only at \
                     creation, so they take effect after ade rm and ade create"
                    (String.concat ", " changed))))

(* Mounts are resolved immediately before creation, on the host that will run
   the machine, so a symlink swapped after the declaration was written is
   still caught. *)
let create_machine t declaration =
  let* mounts = Host_mount.for_declaration ~paths:t.paths declaration in
  let* () = Smolvm.create t.smolvm declaration ~mounts in
  record_creation t declaration

let with_lock t declaration action =
  Workbench_lock.with_lock t.paths (Declaration.name declaration) action

let halt t name = Boot.stop ~services:t.services ~smolvm:t.smolvm ~paths:t.paths name

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error reason ->
    Error (Ade_error.Declaration_invalid { path; reason })

(* The script runs under a Maintenance boot: the guest is installing software
   from the network, so it holds neither the SSH identity nor credentials. The
   machine is stopped whether or not the script succeeded, so a failure never
   leaves a half-provisioned guest running with the agents' access. *)
let run_provision t declaration script =
  let name = Declaration.name declaration in
  let* source = read_file script in
  let* () =
    Boot.start ~services:t.services ~smolvm:t.smolvm ~paths:t.paths ~name
      ~purpose:Boot.Maintenance declaration
  in
  let ran =
    match Smolvm.exec_with_stdin t.smolvm name [ "bash"; "-s" ] ~stdin:source with
    | Error _ as error -> error
    | Ok { Process_runner.status = 0; _ } -> Ok ()
    | Ok { Process_runner.status; stderr; _ } ->
        Error (Ade_error.Runtime_failed { argv = [ "provision"; script ]; status; stderr })
  in
  let stopped = halt t name in
  let* () = ran in
  stopped

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
      let* state = Smolvm.state t.smolvm name in
      match state with
      | Smolvm.Absent ->
          let* () = create_and_provision t declaration in
          Ok Changed
      | _ -> (
          (* Creating an existing machine is a no-op when it matches, and a
             drift report otherwise. It never recreates the machine, because
             that would destroy the workspace. *)
          let* drift = drift_of t declaration in
          match drift with
          | None -> Ok Converged
          | Some reason ->
              Error
                (Ade_error.Declaration_invalid
                   { path = Workbench_name.to_string name; reason })))

(* Starting is expressed as "ensure running", so a running machine converges as
   a no-op after its state is confirmed. *)
let boot t declaration =
  Boot.start ~services:t.services ~smolvm:t.smolvm ~paths:t.paths
    ~name:(Declaration.name declaration) ~purpose:Boot.Work declaration

let ensure_running t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  match state with
  | Smolvm.Running -> Ok Converged
  | Smolvm.Created | Smolvm.Stopped ->
      let* () = boot t declaration in
      Ok Changed
  | Smolvm.Absent ->
      let* () = create_and_provision t declaration in
      let* () = boot t declaration in
      Ok Changed

let start t declaration = with_lock t declaration (fun () -> ensure_running t declaration)

let stop t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      match state with
      | Smolvm.Stopped | Smolvm.Created | Smolvm.Absent ->
          (* The machine may have stopped without ADE; its agent must not
             outlive it. *)
          let* () = Boot.release_agent ~services:t.services ~paths:t.paths name in
          Ok Converged
      | Smolvm.Running ->
          let* () = halt t name in
          Ok Changed)

let restart t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      let* () =
        match state with
        | Smolvm.Running -> halt t name
        | _ -> Ok ()
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
          let* state = Smolvm.state t.smolvm name in
          match state with
          | Smolvm.Running ->
              Error
                (Ade_error.Operation_refused
                   { operation = "provision";
                     reason = "the workbench is running; stop it first" })
          | Smolvm.Absent ->
              let* () = create_and_provision t declaration in
              Ok Changed
          | Smolvm.Created | Smolvm.Stopped ->
              let* () = run_provision t declaration script in
              Ok Changed))

let pull t declaration ~repo =
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
  match Process_runner.find_executable "git" with
  | None -> Error (Ade_error.Runtime_unavailable { executable = "git" })
  | Some git ->
      Pull.run ~smolvm:t.smolvm ~runner:Process_runner.run ~git ~paths:t.paths declaration
        ~repo

let remove t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      let* () = match state with Smolvm.Running -> halt t name | _ -> Ok () in
      let* () =
        match state with Smolvm.Absent -> Ok () | _ -> Smolvm.delete t.smolvm name
      in
      let* () = Boot.release_agent ~services:t.services ~paths:t.paths name in
      let dir = State_paths.workbench_dir t.paths name in
      match Bos.OS.Dir.delete ~recurse:true (Fpath.v dir) with
      | Error (`Msg reason) ->
          Error (Ade_error.Operation_refused { operation = "rm"; reason })
      | Ok () -> Ok (if state = Smolvm.Absent then Converged else Changed))

let attach t declaration ~command =
  (* The machine is brought up under the lock, but the lock is released before
     attaching: an interactive session may last hours and must not block every
     other operation on the workbench. *)
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
  (* With Herdr enabled, a bare attach lands in Herdr, which connects to the
     guest's server or spawns it. Agents are started by the user from there. *)
  let command =
    match command with
    | [] when Declaration.herdr_enabled declaration -> [ "herdr" ]
    | command -> command
  in
  Smolvm.attach t.smolvm (Declaration.name declaration) ~command

let exec t declaration command =
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
  Smolvm.exec t.smolvm (Declaration.name declaration) command

type status = { name : string; state : Smolvm.state; drift : string option }

let status t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  let* drift = drift_of t declaration in
  Ok { name = Workbench_name.to_string name; state; drift }
