type t = { path : string; fd : Unix.file_descr }

(* Two different mechanisms are needed, because they exclude different things.

   A POSIX record lock (lockf) excludes a *separate* ADE process, and the kernel
   drops it when its owner dies, so a crash cannot leave the workbench locked
   forever. An O_EXCL file would: its existence is the lock, and nothing
   removes it after a crash.

   The in-process table excludes a second acquisition inside *one* process.
   Record locks are owned by the process, so a second lockf on the same file
   from the same process silently succeeds.

   The file is never unlinked on release: removing it would let a third process
   lock a fresh file while a second still holds the old one. *)
let held : (string, unit) Hashtbl.t = Hashtbl.create 8

let conflict name =
  Ade_error.Operation_refused
    {
      operation = "lock workbench";
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
        match Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600 with
        | exception Unix.Unix_error (error, _, _) ->
            Error
              (Ade_error.Runtime_output_invalid
                 { context = "workbench lock"; reason = Unix.error_message error })
        | fd -> (
            match Unix.lockf fd Unix.F_TLOCK 0 with
            | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
                Unix.close fd;
                Error (conflict name)
            | exception Unix.Unix_error (error, _, _) ->
                Unix.close fd;
                Error
                  (Ade_error.Runtime_output_invalid
                     { context = "workbench lock"; reason = Unix.error_message error })
            | () ->
                (* Recorded for diagnostics; the held lock is the lock. *)
                let payload = Printf.sprintf "%d\n" (Unix.getpid ()) in
                ignore (Unix.ftruncate fd 0);
                ignore (Unix.write_substring fd payload 0 (String.length payload));
                Hashtbl.replace held path ();
                Ok { path; fd }))

let release t =
  Hashtbl.remove held t.path;
  (* Closing drops the record lock. *)
  try Unix.close t.fd with Unix.Unix_error _ -> ()

let with_lock paths name action =
  match acquire paths name with
  | Error _ as error -> error
  | Ok lock ->
      let result = try action () with exn -> release lock; raise exn in
      release lock;
      result
