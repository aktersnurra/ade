type source =
  | Keychain of { item : string }
  | File of { path : string }
  | Pass of { entry : string }

(* A t holds only a locator. Nothing here can carry a credential, which is what
   stops one being written into a declaration and committed. *)
type t = { source : source }

let keychain ~item = { source = Keychain { item } }
let file ~path = { source = File { path } }
let pass ~entry = { source = Pass { entry } }
let source t = t.source

let expand_home path =
  if String.length path >= 2 && String.sub path 0 2 = "~/" then
    match Sys.getenv_opt "HOME" with
    | Some home -> Filename.concat home (String.sub path 2 (String.length path - 2))
    | None -> path
  else path

let of_reference reference =
  let prefixed prefix =
    let length = String.length prefix in
    String.length reference > length && String.sub reference 0 length = prefix
  in
  let after prefix =
    let length = String.length prefix in
    String.sub reference length (String.length reference - length)
  in
  if reference = "" then Error "the credential reference is empty"
  else if prefixed "keychain:" then
    let item = after "keychain:" in
    if item = "" then Error "the keychain reference names no item"
    else Ok (keychain ~item)
  else if prefixed "pass:" then
    let entry = after "pass:" in
    (* An entry name is a path inside the store; it must not climb out of it
       or be read by pass as an option. *)
    if entry = "" then Error "the pass reference names no entry"
    else if entry.[0] = '-' || entry.[0] = '/' then
      Error ("the pass entry " ^ Filename.quote entry ^ " must be a relative store path")
    else if List.mem ".." (String.split_on_char '/' entry) then
      Error ("the pass entry " ^ Filename.quote entry ^ " must not contain '..'")
    else Ok (pass ~entry)
  else if prefixed "file:" then
    let path = after "file:" in
    if path = "" then Error "the file reference names no path" else Ok (file ~path)
  else if String.contains reference ':' then
    Error
      ("unknown credential reference scheme in " ^ Filename.quote reference
     ^ "; expected keychain: or file:")
  else
    (* A bare path stays valid so existing declarations keep working. *)
    Ok (file ~path:reference)

let describe t =
  match t.source with
  | Keychain { item } -> "keychain item " ^ item
  | File { path } -> "file " ^ path
  | Pass { entry } -> "pass entry " ^ entry

type reader = source -> (string, Ade_error.t) result

let read_file path =
  let path = expand_home path in
  if not (Sys.file_exists path) then
    Error
      (Ade_error.Operation_refused
         { operation = "read credential"; reason = "no file at " ^ path })
  else
    try
      let channel = open_in_bin path in
      let length = in_channel_length channel in
      let contents = really_input_string channel length in
      close_in channel;
      Ok contents
    with Sys_error reason ->
      Error
        (Ade_error.Operation_refused { operation = "read credential"; reason })

let find_on_path program =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  List.find_map
    (fun dir ->
      let candidate = Filename.concat dir program in
      if dir <> "" && Sys.file_exists candidate then Some candidate else None)
    (String.split_on_char ':' path)

(* pass drives gpg, and gpg-agent's pinentry needs to find the user's session
   to ask for a passphrase. Only what that requires is forwarded. *)
let pass_environment () =
  List.filter_map
    (fun name -> Option.map (fun value -> (name, value)) (Sys.getenv_opt name))
    [ "PATH"; "HOME"; "PASSWORD_STORE_DIR"; "PASSWORD_STORE_GPG_OPTS"; "GNUPGHOME";
      "GPG_TTY"; "DISPLAY"; "WAYLAND_DISPLAY"; "XDG_RUNTIME_DIR";
      "DBUS_SESSION_BUS_ADDRESS" ]

let default_reader ~runner = function
  | File { path } -> read_file path
  | Pass { entry } -> (
      match find_on_path "pass" with
      | None ->
          Error
            (Ade_error.Operation_refused
               { operation = "read credential"; reason = "pass is not on PATH" })
      | Some executable -> (
          (* "--" keeps the entry from ever being read as an option. *)
          let request =
            {
              Process_runner.executable;
              argv = [ "show"; "--"; entry ];
              env = pass_environment ();
              stdin = None;
              stdio = Process_runner.Capture;
            }
          in
          match runner request with
          | Error error -> Error error
          | Ok { Process_runner.status = 0; stdout; _ } when stdout <> "" -> Ok stdout
          | Ok { Process_runner.status; _ } ->
              Error
                (Ade_error.Operation_refused
                   {
                     operation = "read credential";
                     reason =
                       Printf.sprintf "pass entry %s is not readable (pass exited %d)" entry
                         status;
                   })))
  | Keychain { item } -> (
      (* The item name is an argument, which is fine: it is a locator. The
         credential comes back on stdout and is never passed as one. *)
      let request =
        {
          Process_runner.executable = "/usr/bin/security";
          argv = [ "find-generic-password"; "-w"; "-s"; item ];
          env = [ ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin") ];
          stdin = None;
          stdio = Process_runner.Capture;
        }
      in
      match runner request with
      | Error error -> Error error
      | Ok { Process_runner.status = 0; stdout; _ } ->
          (* security appends a newline that the credential does not include. *)
          Ok (String.trim stdout)
      | Ok { Process_runner.status; _ } ->
          Error
            (Ade_error.Operation_refused
               {
                 operation = "read credential";
                 reason =
                   Printf.sprintf "keychain item %s is not readable (security exited %d)"
                     item status;
               }))

let with_value ?reader t ~f =
  let reader =
    match reader with Some reader -> reader | None -> default_reader ~runner:Process_runner.run
  in
  match reader t.source with
  | Error _ as error -> error
  | Ok value ->
      (* The callback must keep the bytes out of diagnostics and retained state.
         Its type encourages immediate use but cannot enforce non-escape. *)
      f value
