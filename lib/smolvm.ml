type state = Absent | Created | Stopped | Running

type t = { executable : string; runner : Process_runner.t }

let make ~executable ~runner = { executable; runner }

(* The runtime locates its own machine state through HOME and the XDG base
   directories. Forwarding them is what lets a caller point ADE at an isolated
   runtime state directory; without them the runtime silently reads the
   invoking user's real machines, which is both wrong and dangerous during
   qualification. Nothing else from the host environment is passed. *)
let forwarded_environment () =
  let pass name =
    match Sys.getenv_opt name with Some value -> [ (name, value) ] | None -> []
  in
  ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin")
  :: List.concat_map pass
       [ "HOME"; "XDG_DATA_HOME"; "XDG_CACHE_HOME"; "XDG_CONFIG_HOME";
         "XDG_STATE_HOME"; "SMOLVM_AGENT_ROOTFS"; "SMOLVM_LIB_DIR" ]

let request t ?stdin ?(stdio = Process_runner.Capture) argv =
  {
    Process_runner.executable = t.executable;
    argv;
    env = forwarded_environment ();
    stdin;
    stdio;
  }

let succeeded t argv =
  match t.runner (request t argv) with
  | Error _ as error -> error
  | Ok { status = 0; _ } -> Ok ()
  | Ok { status; stderr; _ } ->
      Error
        (Ade_error.Runtime_failed { argv = t.executable :: argv; status; stderr })

(* SmolVM reports more states than ADE acts on. Booting and stopping are
   transient views of a machine that exists and is not yet usable; ADE maps them
   onto the nearest settled state rather than inventing a fifth variant. A
   failed machine exists but must not be treated as running. *)
let parse_state = function
  | "created" -> Ok Created
  | "booting" | "ready" | "running" -> Ok Running
  | "stopping" | "stopped" -> Ok Stopped
  | other when String.length other >= 6 && String.sub other 0 6 = "failed" -> Ok Stopped
  | other -> Error ("unrecognized machine state " ^ Filename.quote other)

let state t name =
  let machine = Workbench_name.to_string name in
  match t.runner (request t [ "machine"; "status"; "--name"; machine; "--json" ]) with
  | Error _ as error -> error
  | Ok { status; stdout; stderr } -> (
      if status <> 0 then
        (* An unknown machine is a normal, expected answer, not a failure. *)
        let haystack = stderr ^ stdout in
        let mentions_missing =
          let needle = "not found" in
          let hl = String.length haystack and nl = String.length needle in
          let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
          scan 0
        in
        if mentions_missing then Ok Absent
        else
          Error
            (Ade_error.Runtime_failed
               { argv = [ t.executable; "machine status" ]; status; stderr })
      else
        match Yojson.Safe.from_string stdout with
        | exception Yojson.Json_error reason ->
            Error (Ade_error.Runtime_output_invalid { context = "machine status"; reason })
        | json -> (
            match Yojson.Safe.Util.member "state" json with
            | `String value -> (
                match parse_state value with
                | Ok state -> Ok state
                | Error reason ->
                    Error
                      (Ade_error.Runtime_output_invalid
                         { context = "machine status"; reason }))
            | _ ->
                Error
                  (Ade_error.Runtime_output_invalid
                     { context = "machine status"; reason = "missing string field 'state'" })))

(* One place builds the create argv, so the declaration is the only source of a
   machine's resources and network posture. *)
let create_argv declaration ~mounts =
  let name = Workbench_name.to_string (Declaration.name declaration) in
  let resources = Declaration.resources declaration in
  (* A locally built image is passed by path. SmolVM would otherwise try to
     pull it from a registry, which fails for a networked workbench and cannot
     even be attempted by a sealed one. *)
  let image =
    match Declaration.image declaration with
    | Declaration.Registry { reference } -> reference
    | Declaration.Local_artifact { path; _ } -> path
  in
  let base =
    [
      "machine"; "create";
      "--name"; name;
      "--image"; image;
      "--cpus"; string_of_int resources.Declaration.cpus;
      "--mem"; string_of_int resources.Declaration.memory_mib;
      "--overlay"; string_of_int resources.Declaration.overlay_gib;
      "--storage"; string_of_int resources.Declaration.workspace_gib;
    ]
  in
  let network =
    match Declaration.network declaration with
    (* Networking is opt-in: a sealed workbench simply never passes --net, so
       the machine is created with no network at all. SmolVM exposes no negative
       rules, so an allowlist is expressed only as positive --allow-* entries. *)
    | Declaration.Sealed -> []
    | Declaration.Public -> [ "--net" ]
    | Declaration.Allowlisted { hosts; cidrs } ->
        [ "--net" ]
        @ List.concat_map (fun host -> [ "--allow-host"; host ]) hosts
        @ List.concat_map (fun cidr -> [ "--allow-cidr"; cidr ]) cidrs
    (* The CIDR narrows the IP; the host mediator installed at every start
       enforces the exact TCP port. Mediation requires virtio-net. *)
    | Declaration.Proxied { proxy; _ } ->
        let address = String.sub proxy 0 (String.rindex proxy ':') in
        [ "--net"; "--net-backend"; "virtio-net"; "--allow-cidr"; address ^ "/32" ]
  in
  (* Only mounts that passed the host policy reach the runtime, and the runtime
     re-checks each source against its own list of system paths. *)
  let volumes =
    List.concat_map (fun mount -> [ "--volume"; Host_mount.volume_spec mount ]) mounts
  in
  (* The runtime forwards an agent only into a machine created to accept one,
     and then requires a socket at every start; Boot supplies it. *)
  let ssh =
    match Declaration.ssh declaration with
    | Declaration.Disabled -> []
    | Declaration.Dedicated_agent _ -> [ "--ssh-agent" ]
  in
  base @ network @ volumes @ ssh

let create t declaration ~mounts = succeeded t (create_argv declaration ~mounts)

let start ?ssh_auth_sock ?egress_guard t name =
  let argv = [ "machine"; "start"; "--name"; Workbench_name.to_string name ] in
  let argv =
    match egress_guard with
    | None -> argv
    | Some binding ->
        argv @ [ "--mediated-egress"; "--egress-interceptor"; Egress_guard.address binding ]
  in
  let base = request t argv in
  let base =
    match egress_guard with
    | None -> base
    | Some binding ->
        { base with
          Process_runner.env =
            ("SMOLVM_INTERCEPTOR_TOKEN", Egress_guard.token_hex binding)
            :: base.Process_runner.env }
  in
  let request =
    match ssh_auth_sock with
    | None -> base
    | Some socket ->
        (* The agent socket path is a capability, so it is passed through the
           environment rather than argv, where the process table would expose
           it to every local process. *)
        { base with Process_runner.env = ("SSH_AUTH_SOCK", socket) :: base.Process_runner.env }
  in
  match t.runner request with
  | Error _ as error -> error
  | Ok { status = 0; _ } -> Ok ()
  | Ok { status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = t.executable :: argv; status; stderr })

let stop t name =
  succeeded t [ "machine"; "stop"; "--name"; Workbench_name.to_string name ]

(* SmolVM asks for confirmation and refuses without a terminal. ADE has
   already asked: ade rm requires --yes. *)
let delete t name =
  succeeded t [ "machine"; "delete"; "--name"; Workbench_name.to_string name; "--force" ]

let exec t name command =
  let argv =
    [ "machine"; "exec"; "--name"; Workbench_name.to_string name ] @ ("--" :: command)
  in
  t.runner (request t argv)

let exec_checked t name command =
  let argv =
    [ "machine"; "exec"; "--name"; Workbench_name.to_string name ] @ ("--" :: command)
  in
  succeeded t argv

(* Without -i SmolVM discards piped stdin and still exits 0, so the command
   would run on empty input and report success. *)
let exec_with_stdin t name command ~stdin =
  let argv =
    [ "machine"; "exec"; "-i"; "--name"; Workbench_name.to_string name ] @ ("--" :: command)
  in
  t.runner (request t ~stdin argv)

let attach t name ~command =
  (* machine shell takes no command; a command gets an interactive exec on a
     terminal instead. *)
  let argv =
    match command with
    | [] -> [ "machine"; "shell"; "--name"; Workbench_name.to_string name ]
    | command ->
        [ "machine"; "exec"; "-i"; "-t"; "--name"; Workbench_name.to_string name ]
        @ ("--" :: command)
  in
  (* Attachment must hand the terminal to the child so signals, resize and
     interactive streams behave as if the user ran the shell directly. *)
  match t.runner (request t ~stdio:Process_runner.Inherit argv) with
  | Error _ as error -> error
  | Ok { status = 0; _ } -> Ok ()
  | Ok { status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = t.executable :: argv; status; stderr })
