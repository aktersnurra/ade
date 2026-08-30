type t = { path : string; fd : Unix.file_descr }

(* Two different mechanisms are needed, because they exclude different things.

   O_EXCL creation excludes a *separate* ADE process: the create either wins or
   fails, with no window between checking and creating.

   The in-process table excludes a second acquisition inside *one* process.
   POSIX record locks (lockf) cannot do this: they are owned by the process, so
   a second lockf on the same file from the same process silently succeeds. *)
let held : (string, unit) Hashtbl.t = Hashtbl.create 8

let conflict name =
  Ade_error.Runtime_output_invalid
    {
      context = "workbench lock";
      reason =
        "another ADE operation is already running for " ^ Workbench_name.to_string name;
    }

let acquire paths name =
  let path = State_paths.lock_file paths name in
  match State_paths.ensure_dir (Filename.dirname path) with
  | Error _ as error -> error
  | Ok () ->
      if Hashtbl.mem held path then Error (conflict name)
      else (
        match
          Unix.openfile path [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
        with
        | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Error (conflict name)
        | exception Unix.Unix_error (error, _, _) ->
            Error
              (Ade_error.Runtime_output_invalid
                 { context = "workbench lock"; reason = Unix.error_message error })
        | fd ->
            (* Recorded for diagnostics; the file's existence is the lock. *)
            let payload = Printf.sprintf "%d\n" (Unix.getpid ()) in
            ignore (Unix.write_substring fd payload 0 (String.length payload));
            Hashtbl.replace held path ();
            Ok { path; fd })

let release t =
  Hashtbl.remove held t.path;
  (try Unix.close t.fd with Unix.Unix_error _ -> ());
  try Sys.remove t.path with Sys_error _ -> ()

let with_lock paths name action =
  match acquire paths name with
  | Error _ as error -> error
  | Ok lock ->
      let result = try action () with exn -> release lock; raise exn in
      release lock;
      result
