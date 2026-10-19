type stdio = Capture | Inherit

type request = {
  executable : string;
  argv : string list;
  env : (string * string) list;
  stdin : string option;
  stdio : stdio;
}

type output = { status : int; stdout : string; stderr : string }
type t = request -> (output, Ade_error.t) result

let render_for_diagnostics request =
  match request.argv with
  | [] -> request.executable
  | subcommand :: _ -> request.executable ^ " " ^ subcommand

let full_argv request = Array.of_list (request.executable :: request.argv)

(* The child environment is the explicit declaration only; the parent
   environment is not inherited, so a stray host variable cannot leak in. *)
let environment request =
  request.env |> List.map (fun (key, value) -> key ^ "=" ^ value) |> Array.of_list

(* stdout, stderr and stdin must be serviced together. Draining one stream to
   completion before the others lets the child block forever on a full pipe. *)
let pump ~stdin_fd ~stdin_payload ~stdout_fd ~stderr_fd =
  let stdout_buffer = Buffer.create 4096 in
  let stderr_buffer = Buffer.create 4096 in
  let chunk = Bytes.create 65536 in
  let pending = ref stdin_payload in
  let stdin_open = ref (stdin_fd <> None) in
  let open_reads = ref [ stdout_fd; stderr_fd ] in
  let close fd =
    open_reads := List.filter (fun other -> other <> fd) !open_reads;
    try Unix.close fd with Unix.Unix_error _ -> ()
  in
  let close_stdin () =
    (match stdin_fd with
     | Some fd -> ( try Unix.close fd with Unix.Unix_error _ -> ())
     | None -> ());
    stdin_open := false
  in
  if !stdin_open && !pending = "" then close_stdin ();
  while !open_reads <> [] || !stdin_open do
    let writes = if !stdin_open then Option.to_list stdin_fd else [] in
    let readable, writable, _ = Unix.select !open_reads writes [] 1.0 in
    List.iter
      (fun fd ->
        let read = try Unix.read fd chunk 0 (Bytes.length chunk) with Unix.Unix_error _ -> 0 in
        if read = 0 then close fd
        else
          Buffer.add_subbytes
            (if fd = stdout_fd then stdout_buffer else stderr_buffer)
            chunk 0 read)
      readable;
    List.iter
      (fun fd ->
        let payload = !pending in
        let written =
          try Unix.write_substring fd payload 0 (String.length payload)
          with Unix.Unix_error _ -> String.length payload
        in
        pending := String.sub payload written (String.length payload - written);
        if !pending = "" then close_stdin ())
      writable
  done;
  (Buffer.contents stdout_buffer, Buffer.contents stderr_buffer)

let status_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal

let find_executable name =
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  String.split_on_char ':' path
  |> List.filter_map (fun dir ->
         if dir = "" then None else Some (Filename.concat dir name))
  |> List.find_opt (fun candidate ->
         try Unix.access candidate [ Unix.X_OK ]; not (Sys.is_directory candidate)
         with Unix.Unix_error _ -> false)

let run request =
  (* A child that exits without reading its stdin would otherwise deliver
     SIGPIPE to ADE on the next write and kill it; the write's EPIPE is
     already handled in [pump]. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  if not (Sys.file_exists request.executable) then
    Error (Ade_error.Runtime_unavailable { executable = request.executable })
  else
    match request.stdio with
    | Inherit -> (
        (* Interactive attachment: the child owns the terminal, so no stream is
           captured and no stdin payload is supplied. *)
        let pid =
          Unix.create_process_env request.executable (full_argv request)
            (environment request) Unix.stdin Unix.stdout Unix.stderr
        in
        match Unix.waitpid [] pid with
        | _, status -> Ok { status = status_code status; stdout = ""; stderr = "" }
        | exception Unix.Unix_error (error, _, _) ->
            Error
              (Ade_error.Runtime_failed
                 {
                   argv = request.executable :: request.argv;
                   status = 1;
                   stderr = Unix.error_message error;
                 }))
    | Capture -> (
        (* The ends the parent keeps are close-on-exec: if the child inherited
           them it would hold the write end of its own stdout open and the
           parent would never see EOF. The ends handed to the child are the
           plain inheritable halves. *)
        let stdout_read, stdout_write = Unix.pipe () in
        let stderr_read, stderr_write = Unix.pipe () in
        let stdin_read, stdin_write = Unix.pipe () in
        Unix.set_close_on_exec stdout_read;
        Unix.set_close_on_exec stderr_read;
        Unix.set_close_on_exec stdin_write;
        match
          Unix.create_process_env request.executable (full_argv request)
            (environment request) stdin_read stdout_write stderr_write
        with
        | exception Unix.Unix_error (error, _, _) ->
            List.iter
              (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())
              [ stdout_read; stdout_write; stderr_read; stderr_write; stdin_read; stdin_write ];
            Error
              (Ade_error.Runtime_failed
                 {
                   argv = request.executable :: request.argv;
                   status = 1;
                   stderr = Unix.error_message error;
                 })
        | pid ->
            Unix.close stdout_write;
            Unix.close stderr_write;
            Unix.close stdin_read;
            (* Secrets are handed to the child on stdin rather than in argv,
               where another local process could read them from the process
               table. *)
            let stdin_payload = Option.value request.stdin ~default:"" in
            let stdin_fd =
              match request.stdin with
              | Some _ -> Some stdin_write
              | None ->
                  Unix.close stdin_write;
                  None
            in
            let stdout, stderr =
              pump ~stdin_fd ~stdin_payload ~stdout_fd:stdout_read ~stderr_fd:stderr_read
            in
            let _, status = Unix.waitpid [] pid in
            Ok { status = status_code status; stdout; stderr })

let replace_process request =
  if not (Sys.file_exists request.executable) then
    Error (Ade_error.Runtime_unavailable { executable = request.executable })
  else
    try Unix.execve request.executable (full_argv request) (environment request)
    with Unix.Unix_error (error, _, _) ->
      Error
        (Ade_error.Runtime_failed
           {
             argv = request.executable :: request.argv;
             status = 1;
             stderr = Unix.error_message error;
           })
