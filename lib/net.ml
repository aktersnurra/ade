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

let persistent_hosts declaration =
  let declared = match proxy_of declaration with Some (_, hosts, _) -> hosts | None -> [] in
  declared @ read_lines (allow_file declaration)

let session_hosts ~paths name =
  read_lines (State_paths.session_allow_file paths name)
  @ read_lines (State_paths.auto_allow_file paths name)

let allowed_hosts ~paths declaration =
  persistent_hosts declaration @ session_hosts ~paths (Declaration.name declaration)

let patterns hosts = List.filter_map (fun host -> Result.to_option (Egress.parse_pattern host)) hosts

let is_allowed ~paths declaration (target : Egress.target) =
  let name = Declaration.name declaration in
  (* Host-owned persistent policy is authoritative. A session wildcard, unlike
     persistent policy, must not bypass a user's explicit host revocation. *)
  Egress.allowed (patterns (persistent_hosts declaration)) target
  || (not (List.mem target.host (read_lines (State_paths.revoked_file paths name)))
      && Egress.allowed (patterns (session_hosts ~paths name)) target)

let append path line =
  let* () = State_paths.ensure_dir (Filename.dirname path) in
  try
    let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        ignore (Unix.write_substring fd line 0 (String.length line)));
    Ok ()
  with Unix.Unix_error (error, _, _) -> Error (refused "write" (path ^ ": " ^ Unix.error_message error))

(* Rewritten through a rename, so the proxy, which reads these files for every
   request, sees the old list or the new one and never half of either. *)
let remove_lines path keep =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ -> Ok ()
  | text -> (
      let kept = List.filter keep (String.split_on_char '\n' text) in
      let temporary = path ^ ".tmp" in
      try
        Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o600 temporary
          (fun channel -> Out_channel.output_string channel (String.concat "\n" kept));
        Unix.rename temporary path;
        Ok ()
      with Sys_error reason | Unix.Unix_error (_, _, reason) -> Error (refused "write" reason))

type scope = Session | Always

let allow ~paths declaration ~host ~scope =
  let* _ = require_proxied "net allow" declaration in
  let host = String.lowercase_ascii (String.trim host) in
  let* pattern = Result.map_error (refused "net allow") (Egress.parse_pattern host) in
  let name = Declaration.name declaration in
  let file =
    match scope with
    | Session -> State_paths.session_allow_file paths name
    | Always -> allow_file declaration
  in
  (* Allowing a host is also the way back from revoking it. *)
  let* () =
    remove_lines (State_paths.revoked_file paths name)
      (fun line -> not (Egress.matches_host pattern (String.trim line)))
  in
  let* () = append file (host ^ "\n") in
  Ok file

let revoke ~paths declaration ~host =
  let* _ = require_proxied "net revoke" declaration in
  let host = String.lowercase_ascii (String.trim host) in
  let* target = Result.map_error (refused "net revoke") (Egress.parse_target ~default_port:443 host) in
  let host = target.Egress.host in
  let name = Declaration.name declaration in
  let other line =
    match Egress.parse_target ~default_port:443 (String.trim line) with
    | Ok target -> target.host <> host
    | Error _ -> true (* Keep wildcard grants for the other hosts they cover. *)
  in
  let* () = remove_lines (State_paths.session_allow_file paths name) other in
  let* () = remove_lines (State_paths.auto_allow_file paths name) other in
  let* () = append (State_paths.revoked_file paths name) (host ^ "\n") in
  (* The declaration and NAME.allow are the user's own files and are not
     edited; a host listed there stays allowed, and the caller is told so. *)
  Ok (List.exists (fun pattern -> Egress.matches_host pattern host)
        (patterns (persistent_hosts declaration)))

let events ~paths declaration =
  match
    In_channel.with_open_bin (State_paths.net_log paths (Declaration.name declaration))
      In_channel.input_all
  with
  | exception Sys_error _ -> []
  | text -> Egress.events_of_text text

let pending ~paths declaration =
  let* _ = require_proxied "net pending" declaration in
  Ok (Egress.pending ~allowed:(is_allowed ~paths declaration) (events ~paths declaration))

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
  (try Sys.remove (State_paths.mediated_file paths name) with Sys_error _ -> ());
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
  (* "Allow once", the classifier's allows and revocations all last until the
     workbench next starts. *)
  List.iter
    (fun path -> try Sys.remove path with Sys_error _ -> ())
    [ State_paths.session_allow_file paths name; State_paths.auto_allow_file paths name;
      State_paths.revoked_file paths name ];
  (* A fresh boot must get a fresh capability, never silently reuse one after
     a failed deletion. Recovery through [ensure] deliberately preserves it. *)
  let* () =
    try Unix.unlink (State_paths.guard_file paths name); Ok () with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
    | Unix.Unix_error (error, _, _) -> Error (refused "start proxy" (Unix.error_message error))
  in
  let* () = launch ~paths declaration in
  match proxy_of declaration with
  | None -> Ok None
  | Some _ ->
      Result.map Option.some
        (Result.map_error (refused "start proxy") (Egress_guard.load (State_paths.guard_file paths name)))

let mark_started ~paths name = append (State_paths.mediated_file paths name) ""

let ensure ~paths declaration =
  let name = Declaration.name declaration in
  match proxy_of declaration with
  | None -> Ok ()
  | Some _ ->
      if not (Sys.file_exists (State_paths.mediated_file paths name)) then
        Error (refused "start proxy" "this running workbench has no mediated boot record; restart it")
      else
        let* _ = Result.map_error (refused "start proxy")
            (Egress_guard.load (State_paths.guard_file paths name)) in
        if running_pid ~paths name <> None then Ok () else launch ~paths declaration

let recorder ~paths name =
  let lock = Mutex.create () in
  let path = State_paths.net_log paths name in
  fun event ->
    Mutex.protect lock (fun () -> ignore (append path (Egress.event_to_line event)))

type classify =
  target:Egress.target -> allowed:string list -> recent:string list -> Egress.verdict * string

let classifier_of ~workbench = function
  | None -> None
  | Some { Declaration.model; api_key_ref } -> (
      match Secret.of_reference api_key_ref with
      | Error reason ->
          prerr_endline ("ade: classifier disabled: network.classifier.api_key_ref: " ^ reason);
          None
      | Ok api_key ->
          let config = { Egress_classifier.model; api_key } in
          Some
            (fun ~target ~allowed ~recent ->
              Egress_classifier.classify config ~workbench ~target ~allowed ~recent))

(* Decides a destination no pattern allows. Each target is decided once per
   proxy run: a second request for it waits for the first answer, and the
   answer is kept, so retries cost nothing. An allow is written to the
   auto-allowed list as the exact host and port, and from then on matches as a
   pattern. A revoked host is refused before anything else is asked. *)
let decider ~paths ~name ~record ~allowed ~(classify : classify option) =
  let lock = Mutex.create () in
  let decided : (Egress.target, Egress.verdict * string) Hashtbl.t = Hashtbl.create 16 in
  let in_flight = Hashtbl.create 16 in
  let recent = ref [] in
  let classified (target : Egress.target) verdict reason =
    record (Egress.Classified { time = Unix.gettimeofday (); host = target.host; verdict; reason });
    if verdict = Egress.Allow then
      ignore (append (State_paths.auto_allow_file paths name) (Egress.render_target target ^ "\n"))
  in
  let verdict_for (target : Egress.target) =
    match Egress.unusual_shape target with
    | Some shape -> (Egress.Ask, "the name is " ^ shape)
    | None -> (
        match classify with
        | None -> (Egress.Ask, "")
        | Some classify ->
            let recent = Mutex.protect lock (fun () -> !recent) in
            classify ~target ~allowed:(allowed ()) ~recent)
  in
  let rec wait_for target deadline =
    match Mutex.protect lock (fun () -> Hashtbl.find_opt decided target) with
    | Some answer -> answer
    | None when Unix.gettimeofday () > deadline -> (Egress.Unavailable, "no answer in time")
    | None ->
        Thread.delay 0.05;
        wait_for target deadline
  in
  fun (target : Egress.target) ->
    let revoked = List.mem target.host (read_lines (State_paths.revoked_file paths name)) in
    if revoked then Egress_proxy.Refuse (Some "the user revoked it on the host")
    else
      let mine =
        Mutex.protect lock (fun () ->
            recent := target.host :: List.filteri (fun i host -> i < 19 && host <> target.host) !recent;
            if Hashtbl.mem decided target || Hashtbl.mem in_flight target then false
            else (
              Hashtbl.replace in_flight target ();
              true))
      in
      let verdict, reason =
        if mine then (
          let verdict, reason =
            try verdict_for target with exn -> (Egress.Unavailable, Printexc.to_string exn)
          in
          classified target verdict reason;
          Mutex.protect lock (fun () ->
              Hashtbl.replace decided target (verdict, reason);
              Hashtbl.remove in_flight target);
          (verdict, reason))
        else
          wait_for target
            (Unix.gettimeofday () +. float_of_int Egress_classifier.timeout_seconds +. 5.0)
      in
      let because prefix = if reason = "" then prefix else prefix ^ " (" ^ reason ^ ")" in
      match verdict with
      | Egress.Allow -> Egress_proxy.Pass
      | Egress.Deny -> Egress_proxy.Refuse (Some (because "the classifier denied it"))
      | Egress.Ask | Egress.Unavailable ->
          Egress_proxy.Refuse
            (if reason = "" then None else Some (because "it needs the user's approval"))

let serve ~paths ~declaration_path =
  let* declaration = Declaration.load declaration_path in
  let* proxy, _, classifier = require_proxied "net serve" declaration in
  let name = Declaration.name declaration in
  let* () = State_paths.ensure_dir (State_paths.net_dir paths name) in
  let* socket = Result.map_error (refused "net serve") (Egress_proxy.listen proxy) in
  let guard_path = State_paths.guard_file paths name in
  let* previous =
    if Sys.file_exists guard_path then
      Result.map Option.some (Result.map_error (refused "net serve") (Egress_guard.load guard_path))
    else Ok None
  in
  let* binding, guard_socket = Result.map_error (refused "net serve")
      (Egress_guard.listen ?binding:previous ~proxy ()) in
  let* () = Result.map_error (refused "net serve") (Egress_guard.save guard_path binding) in
  let pid_path = State_paths.proxy_pid_file paths name in
  let pid_fd = Unix.openfile pid_path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  match Unix.lockf pid_fd Unix.F_TLOCK 0 with
  | exception Unix.Unix_error _ -> Error (refused "net serve" "a proxy is already running")
  | () ->
      Unix.ftruncate pid_fd 0;
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
      let decide =
        decider ~paths ~name ~record
          ~allowed:(fun () -> allowed_hosts ~paths (current ()))
          ~classify:(classifier_of ~workbench:(Workbench_name.to_string name) classifier)
      in
      let config =
        {
          Egress_proxy.workbench = Workbench_name.to_string name;
          is_allowed = (fun target -> is_allowed ~paths (current ()) target);
          decide;
          record;
          resolve = Egress_proxy.default_resolve;
        }
      in
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      ignore (Thread.create (Egress_guard.serve binding) guard_socket);
      (* Publish readiness only after both listeners and the binding exist. *)
      let pid = Printf.sprintf "%d\n" (Unix.getpid ()) in
      ignore (Unix.write_substring pid_fd pid 0 (String.length pid));
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
     This machine reaches the network only through ADE's egress proxy. Most \
     hosts a coding task needs are allowed, many of them automatically the \
     first time you use them. A host that is not allowed fails with HTTP 403 \
     from the proxy (curl prints `CONNECT tunnel failed, response 403`); the \
     response body says why.\n\n\
     There is no other route out, and nothing inside this machine can change \
     what is allowed. Do not try to work around a block: no mirror, raw IP, \
     other port or tool will get through, and trying looks like exfiltration.\n\n\
     When you hit a block, stop and tell the user which host you need and why. \
     They can allow it on the host with `ade net allow %s HOST`. Retry after \
     they confirm.\n"
    workbench

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
