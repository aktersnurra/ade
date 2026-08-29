type network =
  | Sealed
  | Public
  | Allowlisted of { hosts : string list; cidrs : string list }

type ssh =
  | Disabled
  | Dedicated_agent of { key_ref : string }

type resources = {
  cpus : int;
  memory_mib : int;
  overlay_gib : int;
  workspace_gib : int;
}

type backup = { directory : string; keep : int }

type t = {
  name : Workbench_name.t;
  image : string;
  smolfile : string;
  resources : resources;
  network : network;
  ssh : ssh;
  docker_enabled : bool;
  herdr_enabled : bool;
  backup : backup;
}

let name d = d.name
let image d = d.image
let smolfile d = d.smolfile
let resources d = d.resources
let network d = d.network
let ssh d = d.ssh
let docker_enabled d = d.docker_enabled
let herdr_enabled d = d.herdr_enabled
let backup d = d.backup

(* Parsing is written as a small result-returning reader over the TOML value so
   that every failure carries the declaration path and a concrete reason. *)

exception Invalid of string

let fail reason = raise (Invalid reason)

let table_keys = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> List.map fst pairs
  | _ -> fail "expected a table"

let find table key =
  match table with
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> List.assoc_opt key pairs
  | _ -> fail "expected a table"

let reject_unknown ~context table allowed =
  List.iter
    (fun key ->
      if not (List.mem key allowed) then
        fail (Printf.sprintf "unknown key %s in %s" (Filename.quote key) context))
    (table_keys table)

let require table key context =
  match find table key with
  | Some value -> value
  | None -> fail (Printf.sprintf "missing key %s in %s" (Filename.quote key) context)

let as_string context = function
  | Otoml.TomlString s -> s
  | _ -> fail (context ^ " must be a string")

let as_bool context = function
  | Otoml.TomlBoolean b -> b
  | _ -> fail (context ^ " must be a boolean")

let as_int context = function
  | Otoml.TomlInteger i -> i
  | _ -> fail (context ^ " must be an integer")

let as_string_list context = function
  | Otoml.TomlArray values -> List.map (as_string context) values
  | _ -> fail (context ^ " must be an array of strings")

let positive context value =
  if value <= 0 then fail (context ^ " must be greater than zero") else value

(* The image must be pinned by immutable digest. A moving tag would silently
   change the trusted execution substrate between reimages. *)
let parse_image value =
  let image = as_string "image" value in
  match String.index_opt image '@' with
  | None -> fail "image must be pinned by digest (expected name@sha256:...)"
  | Some at ->
      let digest = String.sub image (at + 1) (String.length image - at - 1) in
      let prefix = "sha256:" in
      let prefix_length = String.length prefix in
      if String.length digest <= prefix_length
         || String.sub digest 0 prefix_length <> prefix
      then fail "image digest must use the sha256: prefix"
      else
        let hex = String.sub digest prefix_length (String.length digest - prefix_length) in
        if String.length hex <> 64 then
          fail "image digest must be 64 hexadecimal characters"
        else if
          not
            (String.for_all
               (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
               hex)
        then fail "image digest must be lowercase hexadecimal"
        else image

let parse_cidr value =
  match String.index_opt value '/' with
  | None -> fail (Printf.sprintf "malformed CIDR %s: missing prefix length" (Filename.quote value))
  | Some slash ->
      let address = String.sub value 0 slash in
      let bits = String.sub value (slash + 1) (String.length value - slash - 1) in
      let octets = String.split_on_char '.' address in
      if List.length octets <> 4 then
        fail (Printf.sprintf "malformed CIDR %s: expected four octets" (Filename.quote value));
      List.iter
        (fun octet ->
          match int_of_string_opt octet with
          | Some n when n >= 0 && n <= 255 -> ()
          | _ ->
              fail
                (Printf.sprintf "malformed CIDR %s: bad octet %s" (Filename.quote value)
                   (Filename.quote octet)))
        octets;
      (match int_of_string_opt bits with
       | Some n when n >= 0 && n <= 32 -> ()
       | _ ->
           fail
             (Printf.sprintf "malformed CIDR %s: prefix length must be 0-32"
                (Filename.quote value)));
      value

let parse_network table =
  reject_unknown ~context:"[network]" table [ "posture"; "hosts"; "cidrs" ];
  let posture = as_string "network.posture" (require table "posture" "[network]") in
  let hosts =
    match find table "hosts" with
    | Some value -> as_string_list "network.hosts" value
    | None -> []
  in
  let cidrs =
    match find table "cidrs" with
    | Some value -> List.map parse_cidr (as_string_list "network.cidrs" value)
    | None -> []
  in
  match posture with
  | "sealed" ->
      if hosts <> [] || cidrs <> [] then
        fail "sealed network must not declare hosts or cidrs";
      Sealed
  | "public" ->
      if hosts <> [] || cidrs <> [] then
        fail "public network must not declare hosts or cidrs";
      Public
  | "allowlisted" ->
      if hosts = [] && cidrs = [] then
        fail "allowlisted network must declare at least one host or CIDR";
      Allowlisted { hosts; cidrs }
  | other ->
      fail
        (Printf.sprintf "unknown network posture %s (expected sealed, public or allowlisted)"
           (Filename.quote other))

let parse_ssh table =
  reject_unknown ~context:"[ssh]" table [ "mode"; "key_ref" ];
  match as_string "ssh.mode" (require table "mode" "[ssh]") with
  | "disabled" -> Disabled
  | "dedicated_agent" ->
      let key_ref = as_string "ssh.key_ref" (require table "key_ref" "[ssh]") in
      if key_ref = "" then fail "ssh.key_ref must not be empty";
      Dedicated_agent { key_ref }
  | other ->
      fail
        (Printf.sprintf "unknown ssh mode %s (expected disabled or dedicated_agent)"
           (Filename.quote other))

let parse_resources table =
  reject_unknown ~context:"[resources]" table
    [ "cpus"; "memory_mib"; "overlay_gib"; "workspace_gib" ];
  {
    cpus = positive "resources.cpus" (as_int "resources.cpus" (require table "cpus" "[resources]"));
    memory_mib =
      positive "resources.memory_mib"
        (as_int "resources.memory_mib" (require table "memory_mib" "[resources]"));
    overlay_gib =
      positive "resources.overlay_gib"
        (as_int "resources.overlay_gib" (require table "overlay_gib" "[resources]"));
    workspace_gib =
      positive "resources.workspace_gib"
        (as_int "resources.workspace_gib" (require table "workspace_gib" "[resources]"));
  }

let parse_services table =
  reject_unknown ~context:"[services]" table [ "docker"; "herdr" ];
  let read key =
    match find table key with
    | Some value -> as_bool ("services." ^ key) value
    | None -> false
  in
  (read "docker", read "herdr")

let parse_backup table =
  reject_unknown ~context:"[backup]" table [ "directory"; "keep" ];
  let directory = as_string "backup.directory" (require table "directory" "[backup]") in
  if directory = "" then fail "backup.directory must not be empty";
  let keep =
    match find table "keep" with
    | Some value -> positive "backup.keep" (as_int "backup.keep" value)
    | None -> 5
  in
  { directory; keep }

let sub_table root key context =
  match find root key with
  | Some (Otoml.TomlTable _ as table) | Some (Otoml.TomlInlineTable _ as table) -> table
  | Some _ -> fail (Printf.sprintf "[%s] must be a table" key)
  | None -> fail (Printf.sprintf "missing table [%s] in %s" key context)

let parse root =
  reject_unknown ~context:"the declaration" root
    [ "name"; "image"; "smolfile"; "resources"; "network"; "services"; "ssh"; "backup" ];
  let name_value = as_string "name" (require root "name" "the declaration") in
  let name =
    match Workbench_name.of_string name_value with
    | Ok name -> name
    | Error reason ->
        fail (Printf.sprintf "invalid workbench name: %s" (Workbench_name.error_reason reason))
  in
  let image = parse_image (require root "image" "the declaration") in
  let smolfile = as_string "smolfile" (require root "smolfile" "the declaration") in
  if smolfile = "" then fail "smolfile must not be empty";
  let resources = parse_resources (sub_table root "resources" "the declaration") in
  let network = parse_network (sub_table root "network" "the declaration") in
  let docker_enabled, herdr_enabled =
    match find root "services" with
    | Some table -> parse_services table
    | None -> (false, false)
  in
  let ssh =
    match find root "ssh" with Some table -> parse_ssh table | None -> Disabled
  in
  let backup = parse_backup (sub_table root "backup" "the declaration") in
  { name; image; smolfile; resources; network; ssh; docker_enabled; herdr_enabled; backup }

let load path =
  if not (Sys.file_exists path) then Error (Ade_error.Declaration_not_found { path })
  else
    match Otoml.Parser.from_file_result path with
    | Error reason -> Error (Ade_error.Declaration_invalid { path; reason })
    | Ok root -> (
        match parse root with
        | declaration -> Ok declaration
        | exception Invalid reason -> Error (Ade_error.Declaration_invalid { path; reason })
        | exception Not_found ->
            Error (Ade_error.Declaration_invalid { path; reason = "malformed table" }))

(* Canonical rendering for the digest. Only ordering-insensitive collections are
   sorted; names, paths and image references are used verbatim. *)
let canonical d =
  let buffer = Buffer.create 512 in
  let line key value = Buffer.add_string buffer (key ^ "=" ^ value ^ "\n") in
  line "name" (Workbench_name.to_string d.name);
  line "image" d.image;
  line "smolfile" d.smolfile;
  line "cpus" (string_of_int d.resources.cpus);
  line "memory_mib" (string_of_int d.resources.memory_mib);
  line "overlay_gib" (string_of_int d.resources.overlay_gib);
  line "workspace_gib" (string_of_int d.resources.workspace_gib);
  (match d.network with
   | Sealed -> line "network" "sealed"
   | Public -> line "network" "public"
   | Allowlisted { hosts; cidrs } ->
       line "network" "allowlisted";
       line "hosts" (String.concat "," (List.sort String.compare hosts));
       line "cidrs" (String.concat "," (List.sort String.compare cidrs)));
  (match d.ssh with
   | Disabled -> line "ssh" "disabled"
   | Dedicated_agent { key_ref } ->
       line "ssh" "dedicated_agent";
       line "ssh_key_ref" key_ref);
  line "docker" (string_of_bool d.docker_enabled);
  line "herdr" (string_of_bool d.herdr_enabled);
  line "backup_directory" d.backup.directory;
  line "backup_keep" (string_of_int d.backup.keep);
  Buffer.contents buffer

let digest_hex d = Digestif.SHA256.(digest_string (canonical d) |> to_hex)
