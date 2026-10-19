let ( let* ) = Result.bind

let refused reason = Error (Ade_error.Operation_refused { operation = "pull"; reason })

(* Host git runs with no user or system config and no prompts. The repository's
   own config still applies, since it is the user's, and the guest has only a
   read-only view of it. *)
let git_request ~git ~directory arguments =
  {
    Process_runner.executable = git;
    argv = "-C" :: directory :: arguments;
    env =
      [ ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin");
        ("GIT_CONFIG_GLOBAL", "/dev/null");
        ("GIT_CONFIG_SYSTEM", "/dev/null");
        ("GIT_TERMINAL_PROMPT", "0") ];
    stdin = None;
    stdio = Process_runner.Capture;
  }

let run_git ~runner ~git ~directory arguments =
  match runner (git_request ~git ~directory arguments) with
  | Error _ as error -> error
  | Ok { Process_runner.status = 0; _ } -> Ok ()
  | Ok { Process_runner.status; stderr; _ } ->
      Error (Ade_error.Runtime_failed { argv = git :: arguments; status; stderr })

(* The outbox is written by the guest, so a symlink there could point git at any
   file the host user can read. Only a regular file is ever opened. *)
let check_regular_file path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> Ok ()
  | _ -> refused (Printf.sprintf "%s is not a regular file" (Filename.quote path))
  | exception Unix.Unix_error (error, _, _) ->
      refused (Printf.sprintf "%s: %s" (Filename.quote path) (Unix.error_message error))

let pull_one ~smolvm ~runner ~git ~outbox ~name ~source repo =
  let bundle_name = repo ^ ".bundle" in
  let* () =
    Smolvm.exec_checked smolvm name
      [ "git"; "-C"; "/workspace/" ^ repo; "bundle"; "create";
        "/outbox/" ^ bundle_name; "--branches" ]
  in
  let bundle = Filename.concat outbox bundle_name in
  let* () = check_regular_file bundle in
  let* () = run_git ~runner ~git ~directory:source [ "bundle"; "verify"; bundle ] in
  (* Agent branches land under refs/remotes/agents/ and are never forced onto
     the user's own branches. fsck rejects malformed objects; submodules are not
     followed, since a fetch must not reach for more of the network. *)
  run_git ~runner ~git ~directory:source
    [ "-c"; "transfer.fsckObjects=true"; "fetch"; "--no-tags"; "--no-recurse-submodules";
      bundle; "+refs/heads/*:refs/remotes/agents/*" ]

let run ~smolvm ~runner ~git ~paths declaration ~repo =
  let name = Declaration.name declaration in
  let* resolved = Host_mount.for_declaration ~paths declaration in
  (* Resolved mounts follow the declared order, with the outbox appended. *)
  let clones =
    List.filter_map
      (fun (mount, resolved) ->
        if mount.Declaration.mode = Declaration.Clone then
          Some (Declaration.clone_name mount, resolved.Host_mount.source)
        else None)
      (List.combine (Declaration.mounts declaration)
         (List.filteri
            (fun i _ -> i < List.length (Declaration.mounts declaration))
            resolved))
  in
  let* selected =
    match repo with
    | None when clones = [] -> refused "the declaration has no clone mounts"
    | None -> Ok clones
    | Some wanted -> (
        match List.filter (fun (repo, _) -> repo = wanted) clones with
        | [] -> refused (Printf.sprintf "no clone mount named %s" (Filename.quote wanted))
        | found -> Ok found)
  in
  let outbox = State_paths.outbox_dir paths name in
  List.fold_left
    (fun acc (repo, source) ->
      let* done_ = acc in
      let* () = pull_one ~smolvm ~runner ~git ~outbox ~name ~source repo in
      Ok (done_ @ [ repo ]))
    (Ok []) selected
