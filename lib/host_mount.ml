type resolved = { source : string; guest : string; read_only : bool }
type repo = { name : string; source : string }
type policy = { home : string; protected : string list }

let ( let* ) = Result.bind

let refused ?(operation = "mount") reason = Error (Ade_error.Operation_refused { operation; reason })

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

(* Where a host path really is, refused when handing it to the guest would
   expose more than the user meant: the home directory or an ancestor of it,
   or a protected store. A repository is checked the same way as a mount: its
   history in a bundle is exposure even without a mount. *)
let resolve_source ~operation policy host =
  let refused = refused ~operation in
  let written = expand_home ~home:policy.home host in
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
  Ok source

let resolve policy (mount : Declaration.mount) =
  let* source = resolve_source ~operation:"mount" policy mount.Declaration.host in
  let read_only = mount.Declaration.mode = Declaration.Read_only in
  let* () =
    if read_only then Ok ()
    else
      match find_vcs_metadata source with
      | Some found ->
          refused
            (Printf.sprintf
               "writable mount %s contains version-control metadata at %s; mount it \
                read-only instead"
               (Filename.quote source) (Filename.quote found))
      | None -> Ok ()
  in
  Ok { source; guest = mount.Declaration.guest; read_only }

(* Bundling needs git history, so anything that is not a git repository is
   refused here rather than at the first start. *)
let resolve_repo policy (repo : Declaration.repo) =
  let* source = resolve_source ~operation:"repo" policy repo.Declaration.host in
  if Sys.file_exists (Filename.concat source ".git") then Ok { name = repo.Declaration.name; source }
  else refused ~operation:"repo" (Printf.sprintf "%s is not a git repository" (Filename.quote source))

let resolve_all policy mounts =
  List.fold_left
    (fun acc mount ->
      let* acc = acc in
      let* resolved = resolve policy mount in
      Ok (resolved :: acc))
    (Ok []) mounts
  |> Result.map List.rev

(* Repositories reach the guest through the inbox, which only the host
   writes, and come back through the outbox, which only the guest writes.
   Both belong to ADE, not to the user, so they need none of the user-path
   policing. Every workbench has both, so a repository can be added without
   recreating the machine. *)
let fixed ~paths declaration =
  let name = Declaration.name declaration in
  [ { source = State_paths.inbox_dir paths name; guest = "/inbox"; read_only = true };
    { source = State_paths.outbox_dir paths name; guest = "/outbox"; read_only = false } ]

let policy_for ~paths declaration =
  match Sys.getenv_opt "HOME" with
  | None | Some "" -> Error "HOME is not set, so host paths cannot be checked"
  | Some home ->
      let declarations_dir = Filename.dirname (canonical (Declaration.path declaration)) in
      Ok (default_policy ~home ~state_root:(State_paths.root paths) ~declarations_dir)

let for_declaration ~paths declaration =
  match Declaration.mounts declaration with
  | [] -> Ok (fixed ~paths declaration)
  | mounts ->
      let* policy = Result.map_error (fun reason ->
          Ade_error.Operation_refused { operation = "mount"; reason })
          (policy_for ~paths declaration) in
      let* resolved = resolve_all policy mounts in
      Ok (resolved @ fixed ~paths declaration)

let repos_for_declaration ~paths declaration =
  match Declaration.repos declaration with
  | [] -> Ok []
  | repos ->
      let* policy = Result.map_error (fun reason ->
          Ade_error.Operation_refused { operation = "repo"; reason })
          (policy_for ~paths declaration) in
      List.fold_left
        (fun acc repo ->
          let* acc = acc in
          let* resolved = resolve_repo policy repo in
          Ok (resolved :: acc))
        (Ok []) repos
      |> Result.map List.rev

let volume_spec (resolved : resolved) =
  resolved.source ^ ":" ^ resolved.guest ^ if resolved.read_only then ":ro" else ""
