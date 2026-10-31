let ( let* ) = Result.bind

let refused reason = Error (Ade_error.Operation_refused { operation = "pull"; reason })

let run_git = Host_git.run

(* The guest can replace or edit the outbox at any point. Inspect the opened
   descriptor before reading, then verify only a private host-owned copy. The
   nonblocking open also prevents a swapped FIFO from hanging the host. *)
let with_staged_bundle ~directory path use =
  try
    let before = Unix.lstat path in
    if before.Unix.st_kind <> Unix.S_REG then refused "bundle is not a regular file"
    else
      let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          let opened = Unix.fstat fd in
          if opened.Unix.st_kind <> Unix.S_REG || opened.st_dev <> before.st_dev
             || opened.st_ino <> before.st_ino then refused "bundle changed while opening"
          else
            let staged, channel = Filename.open_temp_file ~temp_dir:directory
                ~perms:0o600 "pull-" ".bundle" in
            Fun.protect
              ~finally:(fun () -> close_out_noerr channel; Sys.remove staged)
              (fun () ->
                let bytes = Bytes.create 65536 in
                let rec copy () =
                  match Unix.read fd bytes 0 (Bytes.length bytes) with
                  | 0 -> ()
                  | length -> output channel bytes 0 length; copy () in
                copy ();
                close_out channel;
                use staged))
  with
  | Unix.Unix_error (error, _, _) -> refused (Unix.error_message error)
  | Sys_error reason -> refused reason

let pull_one ~smolvm ~runner ~git ~outbox ~name ~source repo =
  let bundle_name = repo ^ ".bundle" in
  let* () =
    Smolvm.exec_checked smolvm name
      [ "git"; "-C"; "/workspace/" ^ repo; "bundle"; "create";
        "/outbox/" ^ bundle_name; "--branches" ]
  in
  let bundle = Filename.concat outbox bundle_name in
  with_staged_bundle ~directory:(Filename.dirname outbox) bundle (fun staged ->
      let* () = run_git ~runner ~git ~directory:source [ "bundle"; "verify"; staged ] in
      (* Only verified private bytes reach git; the guest cannot swap this file. *)
      run_git ~runner ~git ~directory:source
        [ "-c"; "transfer.fsckObjects=true"; "fetch"; "--no-tags"; "--no-recurse-submodules";
          staged; "+refs/heads/*:refs/remotes/agents/*" ])

let run ~smolvm ~runner ~git ~paths ~name ~repo =
  let* synced = Repo_sync.recorded ~paths name in
  let* selected =
    match repo with
    | None when synced = [] -> refused "no repositories have been handed to this workbench"
    | None -> Ok synced
    | Some wanted -> (
        match List.filter (fun (repo, _) -> repo = wanted) synced with
        | [] -> refused (Printf.sprintf "no repository named %s" (Filename.quote wanted))
        | found -> Ok found)
  in
  let outbox = State_paths.outbox_dir paths name in
  List.fold_left
    (fun acc (repo, source) ->
      let* done_ = acc in
      let* () = pull_one ~smolvm ~runner ~git ~outbox ~name ~source repo in
      Ok (done_ @ [ repo ]))
    (Ok []) selected
