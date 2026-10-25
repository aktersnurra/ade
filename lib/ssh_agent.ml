type mode = With_identity of Secret.t | Empty

type t = { socket : string; pid : string; populated : bool }

let socket_path t = t.socket
let is_populated t = t.populated
let pid t = t.pid
let of_record ~socket ~pid ~populated = { socket; pid; populated }

let ( let* ) = Result.bind

let refused operation reason =
  Ade_error.Operation_refused { operation; reason }

let run ?runner request =
  let runner = match runner with Some r -> r | None -> Process_runner.run in
  runner request

let request ?stdin executable argv env =
  {
    Process_runner.executable;
    argv;
    env =
      ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin") :: env;
    stdin;
    stdio = Process_runner.Capture;
  }

(* ssh-agent prints shell assignments; the socket and pid are read from them
   rather than guessed, since the agent chooses its own socket directory. *)
let parse_agent_output output =
  let field name =
    let prefix = name ^ "=" in
    let rec scan = function
      | [] -> None
      | line :: rest -> (
          match String.index_opt line '=' with
          | Some _ when String.length line > String.length prefix
                        && String.sub line 0 (String.length prefix) = prefix ->
              let after =
                String.sub line (String.length prefix)
                  (String.length line - String.length prefix)
              in
              (* Trim at the ';' that ends the shell assignment. *)
              let value =
                match String.index_opt after ';' with
                | Some at -> String.sub after 0 at
                | None -> after
              in
              Some (String.trim value)
          | _ -> scan rest)
    in
    scan
      (List.concat_map
         (fun line -> String.split_on_char ' ' line)
         (String.split_on_char '\n' output))
  in
  match (field "SSH_AUTH_SOCK", field "SSH_AGENT_PID") with
  | Some socket, Some pid -> Ok (socket, pid)
  | _ -> Error "could not read the agent's socket and pid from its output"

let stop ?runner t =
  let kill =
    request "/usr/bin/ssh-agent" [ "-k" ]
      [ ("SSH_AUTH_SOCK", t.socket); ("SSH_AGENT_PID", t.pid) ]
  in
  match run ?runner kill with
  | Error _ as error -> error
  | Ok { Process_runner.status = 0; _ } ->
      (try Sys.remove t.socket with Sys_error _ -> ());
      Ok ()
  | Ok { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = [ "ssh-agent"; "-k" ]; status; stderr })

let record ~paths ~name agent =
  let path = State_paths.ssh_agent_file paths name in
  let* () = State_paths.ensure_dir (Filename.dirname path) in
  let payload = Printf.sprintf "%s\n%s\n%b\n" agent.socket agent.pid agent.populated in
  match Bos.OS.File.write ~mode:0o600 (Fpath.v path) payload with
  | Ok () -> Ok ()
  | Error (`Msg reason) -> Error (refused "record ssh agent" reason)

let start ?runner ~paths ~name ~mode () =
  let* output =
    match run ?runner (request "/usr/bin/ssh-agent" [ "-s" ] []) with
    | Error _ as error -> error
    | Ok { Process_runner.status = 0; stdout; _ } -> Ok stdout
    | Ok { Process_runner.status; stderr; _ } ->
        Error
          (refused "start ssh agent"
             (Printf.sprintf "ssh-agent exited with %d: %s" status (String.trim stderr)))
  in
  let* socket, pid =
    Result.map_error (fun reason -> refused "start ssh agent" reason)
      (parse_agent_output output)
  in
  let agent = { socket; pid; populated = false } in
  match mode with
  (* A maintenance agent stays empty even when an identity is available: the
     export helper runs in a guest ADE does not trust, and it must not be able
     to sign with the workbench's key. *)
  | Empty -> Ok agent
  | With_identity identity -> (
          let loaded =
            Secret.with_value identity ~f:(fun key_bytes ->
                (* ssh-add reads the key on stdin, so it never becomes an
                   argument another local process could read. *)
                let add =
                  request ~stdin:key_bytes "/usr/bin/ssh-add" [ "-" ]
                    [ ("SSH_AUTH_SOCK", socket); ("SSH_AGENT_PID", pid) ]
                in
                match run ?runner add with
                | Error _ as error -> error
                | Ok { Process_runner.status = 0; _ } -> Ok ()
                | Ok { Process_runner.status; stderr; _ } ->
                    Error
                      (refused "load ssh identity"
                         (Printf.sprintf "ssh-add exited with %d: %s" status
                            (String.trim stderr))))
          in
          match loaded with
          | Ok () -> Ok { agent with populated = true }
          | Error cause -> (
              match stop ?runner agent with
              | Ok () -> Error cause
              | Error cleanup ->
                  (* Keep the handle recoverable when releasing it also fails. *)
                  let cleanup = match record ~paths ~name agent with
                    | Ok () -> [ cleanup ] | Error error -> [ cleanup; error ] in
                  Error (Ade_error.Rollback_failed { cause; cleanup })))

let loaded_identities ?runner t =
  let listing =
    request "/usr/bin/ssh-add" [ "-l" ]
      [ ("SSH_AUTH_SOCK", t.socket); ("SSH_AGENT_PID", t.pid) ]
  in
  match run ?runner listing with
  | Error _ as error -> error
  (* ssh-add -l exits 1 with "no identities" for an empty agent, which is a
     normal answer here rather than a failure. *)
  | Ok { Process_runner.status = 1; _ } -> Ok 0
  | Ok { Process_runner.status = 0; stdout; _ } ->
      Ok
        (List.length
           (List.filter (fun line -> String.trim line <> "")
              (String.split_on_char '\n' stdout)))
  | Ok { Process_runner.status; stderr; _ } ->
      Error
        (refused "list ssh identities"
           (Printf.sprintf "ssh-add exited with %d: %s" status (String.trim stderr)))


