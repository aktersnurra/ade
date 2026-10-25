type resolved = { source : string; guest : string; read_only : bool; clone_name : string option }
type policy = { home : string; protected : string list }

let ( let* ) = Result.bind

let refused reason = Error (Ade_error.Operation_refused { operation = "mount"; reason })

(* Protected locations are compared after resolution, so a protected path that
   is itself a symlink (macOS /var -> /private/var, a dotfiles checkout) is
   still caught. A path that does not exist cannot be mounted, but is kept
   verbatim so the comparison is still made. *)
let canonical path = try Unix.realpath path with Unix.Unix_error _ -> path

(* Credential stores and host configuration on Linux and macOS. ~/.config and
   ~/.local/share are protected whole: they hold keyrings, tokens, editor and
   VCS configuration (git, jj), and the ADE runtime itself. *)
let home_protected =
  [ ".ssh"; ".gnupg"; ".aws"; ".azure"; ".kube"; ".docker"; ".password-store";
    ".config"; ".local/share"; ".local/state"; "Library" ]

let default_policy ~home ~state_root ~declarations_dir =
  {
    home = canonical home;
    protected =
      List.map canonical
        (List.map (Filename.concat home) home_protected @ [ state_root; declarations_dir ]);
  }

let is_within ~ancestor path =
  path = ancestor
  || ancestor = "/"
  || (let prefix = ancestor ^ "/" in
      String.length path > String.length prefix
      && String.sub path 0 (String.length prefix) = prefix)

let expand_home ~home path =
  if path = "~" then home
  else if String.length path >= 2 && String.sub path 0 2 = "~/" then
    Filename.concat home (String.sub path 2 (String.length path - 2))
  else path

(* Version-control metadata is executable configuration for the host: git
   hooks and config (core.fsmonitor, filters, aliases) and jj's repository
   config and operation log all act the next time the user runs a VCS command
   in that tree. A writable mount containing one is a way out of the VM, so it
   is refused. The walk is bounded and never follows symlinks; it cannot stop
   the guest creating such a directory later, which is why a writable mount
   should hold data, not a working copy. *)
let vcs_markers = [ ".git"; ".jj" ]
let vcs_search_depth = 4

let find_vcs_metadata root =
  let rec walk depth directory =
    let entries = try Sys.readdir directory with Sys_error _ -> [||] in
    Array.sort String.compare entries;
    let entries = Array.to_list entries in
    match List.find_opt (fun entry -> List.mem entry vcs_markers) entries with
    | Some marker -> Some (Filename.concat directory marker)
    | None when depth >= vcs_search_depth -> None
    | None ->
        List.find_map
          (fun entry ->
            let child = Filename.concat directory entry in
            match Unix.lstat child with
            | { Unix.st_kind = Unix.S_DIR; _ } -> walk (depth + 1) child
            | _ | (exception Unix.Unix_error _) -> None)
          entries
  in
  walk 0 root

let resolve policy (mount : Declaration.mount) =
  let written = expand_home ~home:policy.home mount.Declaration.host in
  let* () =
    if Filename.is_relative written then
      refused (Printf.sprintf "host path %s must be absolute or start with ~/" (Filename.quote written))
    else Ok ()
  in
  let* source =
    match Unix.realpath written with
    | source -> Ok source
    | exception Unix.Unix_error (error, _, _) ->
        refused
          (Printf.sprintf "host path %s: %s" (Filename.quote written) (Unix.error_message error))
  in
  let* () =
    match Unix.stat source with
    | { Unix.st_kind = Unix.S_DIR; _ } -> Ok ()
    | _ -> refused (Printf.sprintf "host path %s is not a directory" (Filename.quote source))
    | exception Unix.Unix_error (error, _, _) ->
        refused (Printf.sprintf "host path %s: %s" (Filename.quote source) (Unix.error_message error))
  in
  let quoted = Filename.quote source in
  let* () =
    (* The home directory, or anything above it, would expose everything. *)
    if is_within ~ancestor:source policy.home then
      refused (Printf.sprintf "host path %s contains the home directory" quoted)
    else Ok ()
  in
  let* () =
    match
      List.find_opt
        (fun protected ->
          is_within ~ancestor:protected source || is_within ~ancestor:source protected)
        policy.protected
    with
    | Some protected ->
        refused
          (Printf.sprintf "host path %s overlaps protected %s" quoted (Filename.quote protected))
    | None -> Ok ()
  in
  let read_only = mount.Declaration.mode <> Declaration.Read_write in
  let* () =
    (* Cloning needs history to bundle back, so anything that is not a git
       repository is refused here rather than at the first pull. *)
    if mount.Declaration.mode = Declaration.Clone
       && not (Sys.file_exists (Filename.concat source ".git"))
    then refused (Printf.sprintf "clone mount %s is not a git repository" quoted)
    else Ok ()
  in
  let* () =
    if read_only then Ok ()
    else
      match find_vcs_metadata source with
      | Some found ->
          refused
            (Printf.sprintf
               "writable mount %s contains version-control metadata at %s; mount it \
                read-only instead"
               quoted (Filename.quote found))
      | None -> Ok ()
  in
  let clone_name = match mount.Declaration.mode with
    | Declaration.Clone -> Some (Declaration.clone_name mount) | _ -> None in
  Ok { source; guest = mount.Declaration.guest; read_only; clone_name }

let resolve_all policy mounts =
  List.fold_left
    (fun acc mount ->
      let* acc = acc in
      let* resolved = resolve policy mount in
      Ok (resolved :: acc))
    (Ok []) mounts
  |> Result.map List.rev

(* The guest returns bundles through one writable directory that belongs to
   ADE, not to the user, so it needs none of the user-path policing. *)
let outbox ~paths declaration =
  let source = State_paths.outbox_dir paths (Declaration.name declaration) in
  { source; guest = "/outbox"; read_only = false; clone_name = None }

let for_declaration ~paths declaration =
  match Declaration.mounts declaration with
  | [] -> Ok []
  | mounts -> (
      match Sys.getenv_opt "HOME" with
      | None | Some "" -> refused "HOME is not set, so mounts cannot be checked"
      | Some home ->
          let declarations_dir =
            Filename.dirname (canonical (Declaration.path declaration))
          in
          let* resolved =
            resolve_all
              (default_policy ~home ~state_root:(State_paths.root paths) ~declarations_dir)
              mounts
          in
          if List.exists (fun m -> m.Declaration.mode = Declaration.Clone) mounts then
            Ok (resolved @ [ outbox ~paths declaration ])
          else Ok resolved)

let volume_spec resolved =
  resolved.source ^ ":" ^ resolved.guest ^ if resolved.read_only then ":ro" else ""
