(* These are persisted facts, not capabilities to bypass Host_mount.resolve. *)
type mount = { source : string; guest : string; read_only : bool }
type t = { name : Workbench_name.t; shape : (string * string) list; mounts : mount list }

let ( let* ) = Result.bind
let name t = t.name

let make declaration mounts =
  { name = Declaration.name declaration;
    shape = List.filter (fun (group, _) -> group <> "mounts") (Declaration.creation_shape declaration);
    mounts = List.map (fun (m : Host_mount.resolved) ->
        { source = m.source; guest = m.guest; read_only = m.read_only }) mounts }

let mount_json m = `Assoc [ "source", `String m.source; "guest", `String m.guest;
    "read_only", `Bool m.read_only ]

let encode t =
  Yojson.Safe.to_string (`Assoc [ "version", `Int 2;
      "name", `String (Workbench_name.to_string t.name);
      "shape", `List (List.map (fun (group, value) -> `List [ `String group; `String value ]) t.shape);
      "mounts", `List (List.map mount_json t.mounts) ])

let changes ~recorded ~current =
  let values t group =
    if group = "mounts" then List.map (fun m -> Yojson.Safe.to_string (mount_json m)) t.mounts
    else List.filter_map (fun (key, value) -> if key = group then Some value else None) t.shape
    |> List.sort String.compare in
  List.filter (fun group ->
      not (List.equal String.equal (List.sort String.compare (values recorded group))
             (List.sort String.compare (values current group))))
    [ "image"; "resources"; "network"; "ssh"; "mounts" ]

let keys fields expected =
  List.equal String.equal (List.sort String.compare (List.map fst fields))
    (List.sort String.compare expected)
let member fields key = Option.value (List.assoc_opt key fields) ~default:`Null
let rec traverse f = function
  | [] -> Ok []
  | x :: xs -> let* y = f x in let* ys = traverse f xs in Ok (y :: ys)
let invalid () = Error "invalid creation manifest schema"
let absolute path = not (Filename.is_relative path) && not (String.contains path '\000')
let decode_mount = function
  | `Assoc fields when keys fields [ "source"; "guest"; "read_only" ] -> (
      match member fields "source", member fields "guest", member fields "read_only" with
      | `String source, `String guest, `Bool read_only when absolute source && absolute guest ->
          Ok { source; guest; read_only }
      | _ -> invalid ())
  | _ -> invalid ()

let decode text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error reason -> Error reason
  | `Assoc fields when keys fields [ "version"; "name"; "shape"; "mounts" ] -> (
      match member fields "version", member fields "name", member fields "shape", member fields "mounts" with
      | `Int 2, `String raw_name, `List pairs, `List mounts ->
          let* name = Result.map_error Workbench_name.error_reason (Workbench_name.of_string raw_name) in
          let* shape = traverse (function
              | `List [ `String group; `String value ] when List.mem group [ "image"; "resources"; "network"; "ssh" ] -> Ok (group, value)
              | _ -> invalid ()) pairs in
          let groups = List.map fst shape |> List.sort_uniq String.compare in
          let* () = if List.equal String.equal groups [ "image"; "network"; "resources"; "ssh" ]
            then Ok () else invalid () in
          let* mounts = traverse decode_mount mounts in
          Ok { name; shape; mounts }
      (* Version 1 had clone mounts; such a machine has no inbox to sync. *)
      | `Int 1, _, _, _ ->
          Error "created by an older ADE with clone mounts; recreate it with ade rm and ade create"
      | `Int _, _, _, _ -> Error "unsupported creation manifest version"
      | _ -> invalid ())
  | _ -> invalid ()

let save ~paths t =
  let* () = State_paths.ensure_dir (State_paths.workbench_dir paths t.name) in
  let path = State_paths.created_file paths t.name in
  match Bos.OS.File.write ~mode:0o600 (Fpath.v path) (encode t) with
  | Ok () -> Ok ()
  | Error (`Msg reason) -> Error (Ade_error.Operation_refused { operation = "record creation"; reason })

let load ~paths name =
  let path = State_paths.created_file paths name in
  let invalid reason = Error (Ade_error.Runtime_output_invalid { context = path; reason }) in
  try
    let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    let channel = Unix.in_channel_of_descr fd in
    let text = Fun.protect ~finally:(fun () -> close_in_noerr channel)
        (fun () -> In_channel.input_all channel) in
    match decode text with
    | Error reason -> invalid reason
    | Ok t when Workbench_name.compare name t.name = 0 -> Ok (Some t)
    | Ok _ -> invalid "manifest belongs to another workbench"
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> invalid (Unix.error_message error)
  | Sys_error reason -> invalid reason
