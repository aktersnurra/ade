type installed = { generation : Credential.generation; path : string }

let ( let* ) = Result.bind

(* tmpfs: everything here is gone on restart, which is why credentials live
   here and nowhere else in the guest. *)
let secrets_root = "/run/ade/secrets"

let generation_dir number = Credential.generation_path ~root:secrets_root number
let current_link = Credential.current_path ~root:secrets_root

(* The value is written to the guest over stdin, never as an argument: another
   local process could read an argument from the process table. *)
let install_argv ~provider ~generation =
  let file =
    Filename.concat (generation_dir generation) (Credential.provider_to_string provider)
  in
  [
    "sh"; "-c";
    Printf.sprintf
      "set -eu; umask 077; mkdir -p %s; cat > %s"
      (Filename.quote (generation_dir generation))
      (Filename.quote file);
  ]

(* The guest's exit status is the only evidence a write or activation worked,
   so a nonzero one is a failure carrying the guest's own message. *)
let checked result =
  match result with
  | Error _ as error -> error
  | Ok { Process_runner.status = 0; _ } -> Ok ()
  | Ok { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = [ "credential install" ]; status; stderr })

let install ~smolvm ~name ~provider ~value ~expires_at ~now ~previous =
  (* Validate before touching the guest: a credential that is empty, already
     expired or long-lived is not what was asked for, and installing it would
     replace a working generation with a broken one. *)
  match Credential.validate ~now ~value ~expires_at with
  | Error reason ->
      Error
        (Ade_error.Operation_refused
           {
             operation = "install credential";
             reason = Credential.describe_validation_error reason;
           })
  | Ok () ->
      let number = Credential.next_number previous in
      let* () =
        checked
          (Smolvm.exec_with_stdin smolvm name (install_argv ~provider ~generation:number)
             ~stdin:value)
      in
      (* Activation is a single atomic rename over the symlink, so a reader
         never observes a half-installed generation. *)
      let* () =
        checked
        @@ Smolvm.exec smolvm name
          [
            "sh"; "-c";
            Printf.sprintf
              "set -eu; ln -sfn %s %s.tmp && mv -T %s.tmp %s"
              (Filename.quote (generation_dir number))
              (Filename.quote current_link)
              (Filename.quote current_link)
              (Filename.quote current_link);
          ]
      in
      Ok
        {
          generation =
            { Credential.number; provider; expires_at; installed_at = now };
          path = generation_dir number;
        }

let revoke ~smolvm ~name ~provider =
  let* () =
    checked
    @@ Smolvm.exec smolvm name
      [
        "sh"; "-c";
        Printf.sprintf "rm -f %s"
          (Filename.quote
             (Filename.concat current_link (Credential.provider_to_string provider)));
      ]
  in
  Ok ()

(* The generation currently active in the guest, read from the [current]
   link. After a boot tmpfs is empty and there is none. *)
let active_generation ~smolvm ~name =
  let* output =
    Smolvm.exec smolvm name
      [ "sh"; "-c"; Printf.sprintf "readlink %s || true" (Filename.quote current_link) ]
  in
  match output with
  | { Process_runner.status = 0; stdout; _ } ->
      let target = Filename.basename (String.trim stdout) in
      Ok (Scanf.sscanf_opt target "generation-%d%!" Fun.id)
  | { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = [ "credential lookup" ]; status; stderr })

let key_argv ~file =
  let path = Filename.concat secrets_root file in
  [
    "sh"; "-c";
    Printf.sprintf "set -eu; umask 077; mkdir -p %s; cat > %s.tmp; mv -f %s.tmp %s"
      (Filename.quote secrets_root) (Filename.quote path) (Filename.quote path)
      (Filename.quote path);
  ]

let install_key ~smolvm ~name ~file ~value =
  if String.length value = 0 then
    Error
      (Ade_error.Operation_refused
         { operation = "install credential"; reason = "the key for " ^ file ^ " is empty" })
  else checked (Smolvm.exec_with_stdin smolvm name (key_argv ~file) ~stdin:value)
