type outcome = Converged | Changed

type t = { smolvm : Smolvm.t; paths : State_paths.t }

let make ~smolvm ~paths = { smolvm; paths }

let ( let* ) = Result.bind

(* Drift is reported, never silently repaired: ADE does not mutate a running
   workbench to resolve a mismatch with the declaration. *)
let drift_of t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  match state with
  | Smolvm.Absent -> Ok None
  | _ ->
      (* V1 stores no shadow lifecycle database, so ADE compares only what
         SmolVM itself reports. A deeper comparison would require recording
         declaration digests per machine, which the design rules out. *)
      Ok None

let with_lock t declaration action =
  Workbench_lock.with_lock t.paths (Declaration.name declaration) action

let create t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      match state with
      | Smolvm.Absent ->
          let* () = Smolvm.create t.smolvm declaration in
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
let ensure_running t declaration =
  let name = Declaration.name declaration in
  let* state = Smolvm.state t.smolvm name in
  match state with
  | Smolvm.Running -> Ok Converged
  | Smolvm.Created | Smolvm.Stopped ->
      let* () = Smolvm.start t.smolvm name in
      Ok Changed
  | Smolvm.Absent ->
      let* () = Smolvm.create t.smolvm declaration in
      let* () = Smolvm.start t.smolvm name in
      Ok Changed

let start t declaration = with_lock t declaration (fun () -> ensure_running t declaration)

let stop t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      match state with
      | Smolvm.Stopped | Smolvm.Created | Smolvm.Absent -> Ok Converged
      | Smolvm.Running ->
          let* () = Smolvm.stop t.smolvm name in
          Ok Changed)

let restart t declaration =
  with_lock t declaration (fun () ->
      let name = Declaration.name declaration in
      let* state = Smolvm.state t.smolvm name in
      let* () =
        match state with
        | Smolvm.Running -> Smolvm.stop t.smolvm name
        | _ -> Ok ()
      in
      let* _ = ensure_running t declaration in
      Ok Changed)

let attach t declaration ~command =
  (* The machine is brought up under the lock, but the lock is released before
     attaching: an interactive session may last hours and must not block every
     other operation on the workbench. *)
  let* _ = with_lock t declaration (fun () -> ensure_running t declaration) in
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
