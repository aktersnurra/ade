type entry_kind =
  | Directory
  | Regular
  | Symlink of { target : string }
  | Hardlink of { target : string }

type entry = { path : string; kind : entry_kind; mode : int }

type rejection =
  | Absolute_path of string
  | Traversing_path of string
  | Hardlink_escapes_root of { path : string; target : string }
  | Device_node of string
  | Socket of string
  | Fifo of string
  | Setuid of string
  | Setgid of string
  | File_capability of string
  | Unexpected_owner of { path : string; uid : int; gid : int }

let describe_rejection = function
  | Absolute_path path -> "absolute path: " ^ path
  | Traversing_path path -> "path escapes the workspace root: " ^ path
  | Hardlink_escapes_root { path; target } ->
      Printf.sprintf "hardlink %s targets %s outside the archive root" path target
  | Device_node path -> "device node: " ^ path
  | Socket path -> "socket: " ^ path
  | Fifo path -> "FIFO: " ^ path
  | Setuid path -> "setuid bit: " ^ path
  | Setgid path -> "setgid bit: " ^ path
  | File_capability path -> "file capability: " ^ path
  | Unexpected_owner { path; uid; gid } ->
      Printf.sprintf "unexpected ownership on %s (uid %d, gid %d)" path uid gid

(* A path is safe when it is relative and every component stays at or below the
   root. Depth is tracked rather than pattern-matching on "..", so a path that
   descends and returns is still accepted, while one that escapes is not. *)
let path_stays_within_root path =
  let components = String.split_on_char '/' path in
  let rec walk depth = function
    | [] -> depth >= 0
    | "" :: rest | "." :: rest -> walk depth rest
    | ".." :: rest -> if depth = 0 then false else walk (depth - 1) rest
    | _ :: rest -> walk (depth + 1) rest
  in
  walk 0 components

let validate_entry ~uid ~gid value =
  ignore uid;
  ignore gid;
  let path = value.path in
  if String.length path > 0 && path.[0] = '/' then Error (Absolute_path path)
  else if not (path_stays_within_root path) then Error (Traversing_path path)
  else if value.mode land 0o4000 <> 0 then Error (Setuid path)
  else if value.mode land 0o2000 <> 0 then Error (Setgid path)
  else
    match value.kind with
    (* A symlink is inert data: it is preserved verbatim, and restoration never
       follows one while creating later entries. A hardlink materializes its
       target's inode inside the workspace, so an escaping target would pull
       host state into the restored tree. *)
    | Symlink _ -> Ok value
    | Hardlink { target } ->
        if String.length target > 0 && target.[0] = '/' then
          Error (Hardlink_escapes_root { path; target })
        else if not (path_stays_within_root target) then
          Error (Hardlink_escapes_root { path; target })
        else Ok value
    | Directory | Regular -> Ok value

let validate_entries ~uid ~gid entries =
  let accepted, rejections =
    List.fold_left
      (fun (accepted, rejections) value ->
        match validate_entry ~uid ~gid value with
        | Ok value -> (value :: accepted, rejections)
        | Error rejection -> (accepted, rejection :: rejections))
      ([], []) entries
  in
  if rejections = [] then Ok (List.rev accepted) else Error (List.rev rejections)

type manifest = { entry_count : int; total_bytes : int; digest_hex : string }

let manifest_digest manifest = manifest.digest_hex

(* The walk uses lstat throughout: following a symlink would let a malicious
   guest make ADE read, hash and report host files as workspace content. *)
let manifest_of_directory root =
  let entries = ref [] in
  let total = ref 0 in
  let failure = ref None in
  let rec walk relative absolute =
    match Unix.lstat absolute with
    | exception Unix.Unix_error (error, _, _) ->
        failure :=
          Some
            (Ade_error.Runtime_output_invalid
               { context = "workspace manifest"; reason = Unix.error_message error })
    | stats -> (
        match stats.Unix.st_kind with
        | Unix.S_DIR ->
            if relative <> "" then entries := (relative, "d", 0) :: !entries;
            let children = try Sys.readdir absolute with Sys_error _ -> [||] in
            Array.sort String.compare children;
            Array.iter
              (fun child ->
                let child_relative =
                  if relative = "" then child else Filename.concat relative child
                in
                walk child_relative (Filename.concat absolute child))
              children
        | Unix.S_REG ->
            total := !total + stats.Unix.st_size;
            entries := (relative, "f", stats.Unix.st_size) :: !entries
        | Unix.S_LNK ->
            let target = try Unix.readlink absolute with Unix.Unix_error _ -> "" in
            entries := (relative ^ " -> " ^ target, "l", 0) :: !entries
        | _ ->
            (* Devices, sockets and FIFOs are never valid workspace content. *)
            entries := (relative, "x", 0) :: !entries)
  in
  walk "" root;
  match !failure with
  | Some error -> Error error
  | None ->
      let sorted =
        List.sort (fun (a, _, _) (b, _, _) -> String.compare a b) !entries
      in
      let buffer = Buffer.create 4096 in
      List.iter
        (fun (path, kind, size) ->
          Buffer.add_string buffer (Printf.sprintf "%s %s %d\n" kind path size))
        sorted;
      Ok
        {
          entry_count = List.length sorted;
          total_bytes = !total;
          digest_hex = Digestif.SHA256.(digest_string (Buffer.contents buffer) |> to_hex);
        }
