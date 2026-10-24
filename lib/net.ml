let ( let* ) = Result.bind

let refused operation reason = Ade_error.Operation_refused { operation; reason }

let proxy_of declaration =
  match Declaration.network declaration with
  | Declaration.Proxied { proxy; hosts; classifier } -> Some (proxy, hosts, classifier)
  | Declaration.Sealed | Declaration.Public | Declaration.Allowlisted _ -> None

let require_proxied operation declaration =
  match proxy_of declaration with
  | Some proxied -> Ok proxied
  | None ->
      Error
        (refused operation
           (Workbench_name.to_string (Declaration.name declaration)
           ^ " is not a proxied workbench (network.posture = \"proxied\")"))

(* Hosts allowed with --always live next to the declaration, in NAME.allow:
   host-owned configuration the user can read, edit and commit with it, kept
   apart so ADE never rewrites a file the user wrote by hand. *)
let allow_file declaration = Filename.remove_extension (Declaration.path declaration) ^ ".allow"

let read_lines path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ -> []
  | text ->
      String.split_on_char '\n' text
      |> List.map String.trim
      |> List.filter (fun line -> line <> "" && not (String.starts_with ~prefix:"#" line))

let allowed_hosts ~paths declaration =
  let declared = match proxy_of declaration with Some (_, hosts, _) -> hosts | None -> [] in
  declared
  @ read_lines (allow_file declaration)
  @ read_lines (State_paths.session_allow_file paths (Declaration.name declaration))

let patterns hosts = List.filter_map (fun host -> Result.to_option (Egress.parse_pattern host)) hosts

let append path line =
  let* () = State_paths.ensure_dir (Filename.dirname path) in
  try
    let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        ignore (Unix.write_substring fd line 0 (String.length line)));
    Ok ()
  with Unix.Unix_error (error, _, _) -> Error (refused "write" (path ^ ": " ^ Unix.error_message error))

type scope = Session | Always

let allow ~paths declaration ~host ~scope =
  let* _ = require_proxied "net allow" declaration in
  let host = String.lowercase_ascii (String.trim host) in
  let* _ = Result.map_error (refused "net allow") (Egress.parse_pattern host) in
  let file =
    match scope with
    | Session -> State_paths.session_allow_file paths (Declaration.name declaration)
    | Always -> allow_file declaration
  in
  let* () = append file (host ^ "\n") in
  Ok file

let events ~paths declaration =
  match
    In_channel.with_open_bin (State_paths.net_log paths (Declaration.name declaration))
      In_channel.input_all
  with
  | exception Sys_error _ -> []
  | text -> Egress.events_of_text text

let pending ~paths declaration =
  let* _ = require_proxied "net pending" declaration in
  let current = patterns (allowed_hosts ~paths declaration) in
  Ok (Egress.pending ~allowed:(Egress.allowed current) (events ~paths declaration))

let log ~paths declaration =
  let* _ = require_proxied "net log" declaration in
  Ok (events ~paths declaration)

(* The proxy holds a lock on its pid file for as long as it runs. A pid is only
   ever signalled while that lock is held, so a stale file whose pid now
   belongs to some other process is never acted on. *)
let running_pid ~paths name =
  let path = State_paths.proxy_pid_file paths name in
  match Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600 with
  | exception Unix.Unix_error _ -> None
  | fd ->
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          match Unix.lockf fd Unix.F_TEST 0 with
          | () -> None
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
              Option.bind
                (In_channel.with_open_bin path In_channel.input_line)
                (fun line -> int_of_string_opt (String.trim line))
          | exception Unix.Unix_error _ -> None)

let wait_until ~seconds condition =
  let deadline = Unix.gettimeofday () +. seconds in
  let rec loop () =
    if condition () then true
    else if Unix.gettimeofday () > deadline then false
    else (
      Unix.sleepf 0.05;
      loop ())
  in
  loop ()

let stop ~paths name =
  match running_pid ~paths name with
  | None -> Ok ()
  | Some pid ->
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      if wait_until ~seconds:3.0 (fun () -> running_pid ~paths name = None) then Ok ()
      else (
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        if wait_until ~seconds:2.0 (fun () -> running_pid ~paths name = None) then Ok ()
        else Error (refused "stop proxy" (Printf.sprintf "the proxy (pid %d) did not exit" pid)))

let tail path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ -> ""
  | text ->
      let lines = List.filter (( <> ) "") (String.split_on_char '\n' (String.trim text)) in
      Egress.sanitize (Option.value (List.nth_opt (List.rev lines) 0) ~default:"")

(* The proxy is ADE itself, re-executed as [ade net serve DECLARATION] in its
   own session, so it outlives the command that started it and stops only when
   the workbench does. It is told the declaration's path rather than its name,
   so it reads exactly the file this command read. *)
let launch ~paths declaration =
  match proxy_of declaration with
  | None -> Ok ()
  | Some _ ->
      let name = Declaration.name declaration in
      let* () = State_paths.ensure_dir (State_paths.net_dir paths name) in
      let output = State_paths.proxy_output_file paths name in
      let executable = Sys.executable_name in
      let argv = [| executable; "net"; "serve"; Declaration.path declaration |] in
      let out = Unix.openfile output [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600 in
      let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      let child =
        match Unix.fork () with
        | 0 -> (
            try
              ignore (Unix.setsid ());
              Unix.dup2 ~cloexec:false null Unix.stdin;
              Unix.dup2 ~cloexec:false out Unix.stdout;
              Unix.dup2 ~cloexec:false out Unix.stderr;
              Unix.execv executable argv
            with _ -> Unix._exit 127)
        | pid -> pid
      in
      Unix.close out;
      Unix.close null;
      let exited () =
        match Unix.waitpid [ Unix.WNOHANG ] child with
        | 0, _ -> false
        | _ -> true
        | exception Unix.Unix_error _ -> true
      in
      let ready = wait_until ~seconds:5.0 (fun () -> running_pid ~paths name <> None || exited ()) in
      if ready && running_pid ~paths name <> None then Ok ()
      else (
        (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
        let reason = match tail output with "" -> "it did not start" | line -> line in
        Error (refused "start proxy" reason))

let start ~paths declaration =
  let name = Declaration.name declaration in
  let* () = stop ~paths name in
  (* "Allow once" lasts until the workbench next starts. *)
  (try Sys.remove (State_paths.session_allow_file paths name) with Sys_error _ -> ());
  launch ~paths declaration

let ensure ~paths declaration =
  if proxy_of declaration = None || running_pid ~paths (Declaration.name declaration) <> None
  then Ok ()
  else launch ~paths declaration

let recorder ~paths name =
  let lock = Mutex.create () in
  let path = State_paths.net_log paths name in
  fun event ->
    Mutex.protect lock (fun () -> ignore (append path (Egress.event_to_line event)))

let serve ~paths ~declaration_path =
  let* declaration = Declaration.load declaration_path in
  let* proxy, _, classifier = require_proxied "net serve" declaration in
  let name = Declaration.name declaration in
  let* () = State_paths.ensure_dir (State_paths.net_dir paths name) in
  let* socket = Result.map_error (refused "net serve") (Egress_proxy.listen proxy) in
  let pid_path = State_paths.proxy_pid_file paths name in
  let pid_fd = Unix.openfile pid_path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  match Unix.lockf pid_fd Unix.F_TLOCK 0 with
  | exception Unix.Unix_error _ -> Error (refused "net serve" "a proxy is already running")
  | () ->
      let pid = Printf.sprintf "%d\n" (Unix.getpid ()) in
      Unix.ftruncate pid_fd 0;
      ignore (Unix.write_substring pid_fd pid 0 (String.length pid));
      let record = recorder ~paths name in
      (* The declaration is re-read for every request, so editing its hosts
         applies to the running workbench; a broken edit keeps the last good
         declaration rather than closing the network or opening it. *)
      let last_good = ref declaration in
      let current () =
        (match Declaration.load declaration_path with
         | Ok fresh -> last_good := fresh
         | Error _ -> ());
        !last_good
      in
      let recent = ref [] in
      let recent_lock = Mutex.create () in
      let classified = Hashtbl.create 16 in
      let classify =
        match classifier with
        | None -> fun _ -> ()
        | Some { Declaration.model; api_key_ref } -> (
            match Secret.of_reference api_key_ref with
            | Error reason ->
                prerr_endline ("ade: classifier disabled: " ^ reason);
                fun _ -> ()
            | Ok api_key ->
                let config = { Egress_classifier.model; api_key } in
                fun (target : Egress.target) ->
                  let fresh =
                    Mutex.protect recent_lock (fun () ->
                        if Hashtbl.mem classified target.host then false
                        else (
                          Hashtbl.replace classified target.host ();
                          true))
                  in
                  if fresh then
                    ignore
                      (Thread.create
                         (fun () ->
                           let recent = Mutex.protect recent_lock (fun () -> !recent) in
                           let verdict, reason =
                             Egress_classifier.classify config
                               ~workbench:(Workbench_name.to_string name) ~target
                               ~allowed:(allowed_hosts ~paths (current ())) ~recent
                           in
                           record
                             (Egress.Classified
                                { time = Unix.gettimeofday (); host = target.host; verdict; reason }))
                         ()))
      in
      let config =
        {
          Egress_proxy.workbench = Workbench_name.to_string name;
          policy = (fun () -> patterns (allowed_hosts ~paths (current ())));
          record =
            (fun event ->
              (match event with
               | Egress.Decision { target; _ } ->
                   Mutex.protect recent_lock (fun () ->
                       recent :=
                         target.host
                         :: List.filteri (fun i host -> i < 19 && host <> target.host) !recent)
               | Egress.Classified _ -> ());
              record event);
          refused = classify;
          resolve = Egress_proxy.default_resolve;
        }
      in
      Egress_proxy.serve config socket

let proxy_url declaration =
  Option.map (fun (proxy, _, _) -> "http://" ^ proxy) (proxy_of declaration)

let environment declaration =
  match proxy_url declaration with
  | None -> []
  | Some url ->
      let local = "localhost,127.0.0.1,::1" in
      [ ("HTTPS_PROXY", url); ("HTTP_PROXY", url); ("https_proxy", url); ("http_proxy", url);
        ("NO_PROXY", local); ("no_proxy", local) ]

let guest_memory ~workbench =
  Printf.sprintf
    "# Network access in this workbench\n\n\
     This machine reaches the network only through ADE's egress proxy, which \
     allows a fixed list of hosts. A request to any other host fails with HTTP \
     403 from the proxy (curl prints `CONNECT tunnel failed, response 403`).\n\n\
     There is no other route out, and nothing inside this machine can change \
     the list. Do not try to work around a block: no mirror, raw IP, other \
     port or tool will get through, and trying looks like exfiltration.\n\n\
     When you hit a block, stop and tell the user which host you need and why. \
     They can allow it on the host with `ade net allow %s HOST`, or list \
     blocked requests with `ade net pending %s`. Retry after they confirm.\n"
    workbench workbench

(* Written at every start: it is not secret, and the proxy's address comes
   from the declaration, not from anything in the guest. Login shells read
   profile.d, interactive ones (Herdr panes) bash.bashrc, and Claude Code reads
   the managed memory file whatever shell it runs under. *)
let write_guest ~smolvm ~name ~what argv contents =
  match Smolvm.exec_with_stdin smolvm name argv ~stdin:contents with
  | Error _ as error -> error
  | Ok { Process_runner.status = 0; _ } -> Ok ()
  | Ok { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = [ what ]; status; stderr })

let configure_guest ~smolvm ~name declaration =
  match environment declaration with
  | [] -> Ok ()
  | environment ->
      let profile =
        String.concat ""
          (List.map
             (fun (key, value) -> Printf.sprintf "export %s=%s\n" key (Filename.quote value))
             environment)
      in
      let* () =
        write_guest ~smolvm ~name ~what:"proxy environment"
          [ "sh"; "-c";
            "set -eu; mkdir -p /etc/profile.d; cat > /etc/profile.d/ade-proxy.sh; \
             grep -qxF '. /etc/profile.d/ade-proxy.sh' /etc/bash.bashrc 2>/dev/null \
             || echo '. /etc/profile.d/ade-proxy.sh' >> /etc/bash.bashrc" ]
          profile
      in
      write_guest ~smolvm ~name ~what:"proxy memory"
        [ "sh"; "-c"; "set -eu; mkdir -p /etc/claude-code; cat > /etc/claude-code/CLAUDE.md" ]
        (guest_memory ~workbench:(Workbench_name.to_string name))
