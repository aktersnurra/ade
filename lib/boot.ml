type purpose = Work | Maintenance

type services = {
  start_agent :
    name:Workbench_name.t ->
    mode:Ssh_agent.mode ->
    identity:Secret.t option ->
    (Ssh_agent.t, Ade_error.t) result;
  stop_agent : Ssh_agent.t -> (unit, Ade_error.t) result;
  install_credentials :
    smolvm:Smolvm.t -> name:Workbench_name.t -> Declaration.t -> (unit, Ade_error.t) result;
  start_proxy : Declaration.t -> (unit, Ade_error.t) result;
  ensure_proxy : Declaration.t -> (unit, Ade_error.t) result;
  stop_proxy : Workbench_name.t -> (unit, Ade_error.t) result;
}

let ( let* ) = Result.bind

let refused reason = Ade_error.Operation_refused { operation = "start"; reason }

let install_github ~smolvm ~name declaration =
  match Declaration.github_credential declaration with
  | None -> Ok ()
  | Some table ->
      let* config =
        Result.map_error
          (fun error -> refused (Github_credential.describe_error error))
          (Github_credential.load_config table)
      in
      (* Right after boot tmpfs is empty and this is the first generation; on
         a refresh of a running workbench it is the one after the active one.
         Only the number of the previous generation is used. *)
      let* active = Credential_installer.active_generation ~smolvm ~name in
      let previous =
        Option.map
          (fun number ->
            { Credential.number; provider = Credential.Github; expires_at = 0.0;
              installed_at = 0.0 })
          active
      in
      let* _ =
        Credential_flow.rotate_github ~smolvm ~name ~config ~now:(Unix.gettimeofday ())
          ~previous ()
      in
      Ok ()

(* pass returns the whole entry, trailing newline included, and a key is one
   line; the guest reads the file verbatim, so the newline is dropped here. *)
let install_anthropic ~smolvm ~name declaration =
  match Declaration.anthropic_api_key_ref declaration with
  | None -> Ok ()
  | Some reference ->
      let* key =
        Result.map_error
          (fun reason -> refused ("credentials.anthropic.api_key_ref: " ^ reason))
          (Secret.of_reference reference)
      in
      Secret.with_value key ~f:(fun value ->
          Credential_installer.install_key ~smolvm ~name ~file:"anthropic"
            ~value:(String.trim value))

let install_credentials ~smolvm ~name declaration =
  let* () = install_github ~smolvm ~name declaration in
  install_anthropic ~smolvm ~name declaration

let default_services ~paths =
  {
    start_agent =
      (fun ~name ~mode ~identity -> Ssh_agent.start ~paths ~name ~mode ~identity ());
    stop_agent = (fun agent -> Ssh_agent.stop agent);
    install_credentials;
    start_proxy = (fun declaration -> Net.start ~paths declaration);
    ensure_proxy = (fun declaration -> Net.ensure ~paths declaration);
    stop_proxy = (fun name -> Net.stop ~paths name);
  }

(* The record is three lines: socket, pid, and whether an identity is loaded.
   It holds no secret; the socket path is a capability, so the file is 0600
   inside the 0700 state directory. *)
let write_record path agent =
  let* () = State_paths.ensure_dir (Filename.dirname path) in
  let payload =
    Printf.sprintf "%s\n%s\n%b\n" (Ssh_agent.socket_path agent) (Ssh_agent.pid agent)
      (Ssh_agent.is_populated agent)
  in
  try
    let temporary = path ^ ".tmp" in
    let fd = Unix.openfile temporary [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600 in
    let written = Unix.write_substring fd payload 0 (String.length payload) in
    Unix.close fd;
    if written <> String.length payload then Error (refused "short write of the agent record")
    else (
      Unix.rename temporary path;
      Ok ())
  with Unix.Unix_error (error, _, _) -> Error (refused (Unix.error_message error))

let read_record path =
  if not (Sys.file_exists path) then None
  else
    try
      let channel = open_in path in
      let socket = input_line channel in
      let pid = input_line channel in
      let populated = bool_of_string (input_line channel) in
      close_in channel;
      Some (Ssh_agent.of_record ~socket ~pid ~populated)
    with Sys_error _ | End_of_file | Invalid_argument _ -> None

let release_agent ~services ~paths name =
  let path = State_paths.ssh_agent_file paths name in
  let result =
    match read_record path with
    (* An agent whose socket is gone is already dead. Its pid may since have
       been reused by an unrelated process, so it is not signalled. *)
    | Some agent when Sys.file_exists (Ssh_agent.socket_path agent) ->
        services.stop_agent agent
    | Some _ | None -> Ok ()
  in
  (try Sys.remove path with Sys_error _ -> ());
  result

let start_agent ~services ~paths ~name ~purpose declaration =
  match Declaration.ssh declaration with
  | Declaration.Disabled -> Ok None
  | Declaration.Dedicated_agent { key_ref } ->
      let* mode, identity =
        match purpose with
        | Maintenance -> Ok (Ssh_agent.Empty, None)
        | Work ->
            Result.map
              (fun identity -> (Ssh_agent.Populated, Some identity))
              (Result.map_error
                 (fun reason -> refused ("ssh.key_ref: " ^ reason))
                 (Secret.of_reference key_ref))
      in
      let* agent = services.start_agent ~name ~mode ~identity in
      (match write_record (State_paths.ssh_agent_file paths name) agent with
       | Ok () -> Ok (Some agent)
       | Error error ->
           ignore (services.stop_agent agent);
           Error error)

(* Everything ADE runs on the host for a workbench, released together. *)
let release ~services ~paths name =
  let agent = release_agent ~services ~paths name in
  let proxy = services.stop_proxy name in
  let* () = agent in
  proxy

let start ~services ~smolvm ~paths ~name ~purpose declaration =
  (* A leftover agent from a run that died is stopped, never reused: it may
     hold an identity this start should not have. *)
  let* () = release ~services ~paths name in
  let* agent = start_agent ~services ~paths ~name ~purpose declaration in
  let undo () = ignore (release ~services ~paths name) in
  (* The proxy is up before the machine boots, so the guest is never running
     without the only route it is allowed to use; provisioning needs it too. *)
  match services.start_proxy declaration with
  | Error error ->
      undo ();
      Error error
  | Ok () -> (
      let ssh_auth_sock = Option.map Ssh_agent.socket_path agent in
      match Smolvm.start ?ssh_auth_sock smolvm name with
      | Error error ->
          undo ();
          Error error
      | Ok () -> (
          let configured =
            let* () = Net.configure_guest ~smolvm ~name declaration in
            match purpose with
            | Maintenance -> Ok ()
            | Work -> services.install_credentials ~smolvm ~name declaration
          in
          match configured with
          | Ok () -> Ok ()
          | Error error ->
              (* A workbench without its declared credentials is not what was
                 asked for; leave it stopped so a retry starts from scratch. *)
              ignore (Smolvm.stop smolvm name);
              undo ();
              Error error))

let stop ~services ~smolvm ~paths name =
  let* () = Smolvm.stop smolvm name in
  release ~services ~paths name
