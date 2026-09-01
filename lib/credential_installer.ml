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
      let* _ =
        Smolvm.exec_with_stdin smolvm name (install_argv ~provider ~generation:number)
          ~stdin:value
      in
      (* Activation is a single atomic rename over the symlink, so a reader
         never observes a half-installed generation. *)
      let* _ =
        Smolvm.exec smolvm name
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
  let* _ =
    Smolvm.exec smolvm name
      [
        "sh"; "-c";
        Printf.sprintf "rm -f %s"
          (Filename.quote
             (Filename.concat current_link (Credential.provider_to_string provider)));
      ]
  in
  Ok ()
