type image =
  | Registry of { reference : string }
  | Local_artifact of { path : string; digest : string }

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

type mount_mode = Read_only | Read_write | Clone
type mount = { host : string; guest : string; mode : mount_mode }

type t = {
  path : string;
  name : Workbench_name.t;
  image : image;
  provision : string option;
  resources : resources;
  network : network;
  ssh : ssh;
  herdr_enabled : bool;
  mounts : mount list;
  github_credential : Otoml.t option;
}

let path d = d.path
let name d = d.name
let image d = d.image

let image_digest d =
  match d.image with
  | Registry { reference } -> (
      match String.index_opt reference '@' with
      | Some at -> String.sub reference (at + 1) (String.length reference - at - 1)
      | None -> reference)
  | Local_artifact { digest; _ } -> digest
let provision d = d.provision
let resources d = d.resources
let network d = d.network
let ssh d = d.ssh
let herdr_enabled d = d.herdr_enabled
let mounts d = d.mounts
let github_credential d = d.github_credential

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

(* A digest, when one is written, must be well formed. It is optional for a
   registry image: the guest runs pacman -Syu, so pinning the base image would
   not pin what the agents run. A local artifact has nothing else to identify
   it and still requires one. *)
let validate_digest digest =
  let prefix = "sha256:" in
  let prefix_length = String.length prefix in
  if String.length digest <= prefix_length || String.sub digest 0 prefix_length <> prefix
  then fail "image digest must use the sha256: prefix"
  else
    let hex = String.sub digest prefix_length (String.length digest - prefix_length) in
    if String.length hex <> 64 then fail "image digest must be 64 hexadecimal characters"
    else if
      not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) hex)
    then fail "image digest must be lowercase hexadecimal"
    else digest

let split_on_digest image =
  match String.index_opt image '@' with
  | None -> fail "image must be pinned by digest (expected name@sha256:... )"
  | Some at ->
      ( String.sub image 0 at,
        String.sub image (at + 1) (String.length image - at - 1) )

let parse_image value =
  let image = as_string "image" value in
  let prefix = "file:" in
  let prefix_length = String.length prefix in
  if String.length image > prefix_length && String.sub image 0 prefix_length = prefix
  then
    (* A locally built image: the tarball path carries the digest of what it
       contains, so the substrate stays pinned even though nothing is pulled. *)
    let rest = String.sub image prefix_length (String.length image - prefix_length) in
    let path, digest = split_on_digest rest in
    if path = "" then fail "the local image reference names no path"
    else Local_artifact { path; digest = validate_digest digest }
  else if image = "" then fail "the image reference names no image"
  else if String.contains image '@' then
    let name, digest = split_on_digest image in
    if name = "" then fail "the image reference names no image"
    else Registry { reference = name ^ "@" ^ validate_digest digest }
  else Registry { reference = image }

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
  reject_unknown ~context:"[services]" table [ "herdr" ];
  match find table "herdr" with
  | Some value -> as_bool "services.herdr" value
  | None -> false

(* Guest paths the runtime or ADE itself owns. A mount at, inside or above one
   of these would hide what ADE relies on: the system, credentials in
   /run/ade/secrets, the storage-backed /workspace (whose export must never
   carry host files), or the maintenance mount points. *)
let reserved_guest_paths =
  [ "/bin"; "/boot"; "/dev"; "/etc"; "/lib"; "/lib64"; "/nix"; "/proc"; "/run";
    "/sbin"; "/sys"; "/tmp"; "/usr"; "/var"; "/workspace"; "/outbox"; "/mnt/ade-export";
    "/mnt/ade-import" ]

let is_within ~ancestor path =
  path = ancestor
  || ancestor = "/"
  || (let prefix = ancestor ^ "/" in
      String.length path > String.length prefix
      && String.sub path 0 (String.length prefix) = prefix)

(* Guest paths must already be in normal form. Normalizing silently would let
   two spellings of one path slip past the overlap check. *)
let validate_guest_path guest =
  let quoted = Filename.quote guest in
  if guest = "" || guest.[0] <> '/' then
    fail (Printf.sprintf "mount guest path %s must be absolute" quoted);
  if String.contains guest ':' then
    fail (Printf.sprintf "mount guest path %s must not contain ':'" quoted);
  if guest = "/" then fail "a mount may not target the guest root";
  (match String.split_on_char '/' guest with
   | "" :: components ->
       if List.exists (fun c -> c = "" || c = "." || c = "..") components then
         fail (Printf.sprintf "mount guest path %s is not in normal form" quoted)
   | _ -> fail (Printf.sprintf "mount guest path %s must be absolute" quoted));
  match
    List.find_opt
      (fun reserved -> is_within ~ancestor:reserved guest || is_within ~ancestor:guest reserved)
      reserved_guest_paths
  with
  | Some reserved ->
      fail (Printf.sprintf "mount guest path %s overlaps reserved %s" quoted reserved)
  | None -> guest

(* The repository's name is the last component of its host path. It becomes a
   file name in /outbox and a directory under /workspace, so it is held to a
   conservative alphabet rather than whatever the host path allowed. *)
let clone_name mount =
  let rec strip path =
    if String.length path > 1 && path.[String.length path - 1] = '/' then
      strip (String.sub path 0 (String.length path - 1))
    else path
  in
  Filename.basename (strip mount.host)

let validate_clone_name name =
  let ok_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  if name = "" || name = "." || name = ".." || name.[0] = '-'
     || not (String.for_all ok_char name)
  then
    fail
      (Printf.sprintf
         "clone mount %s: the repository name must be letters, digits, '.', '_' and '-'"
         (Filename.quote name))

let parse_mount table =
  reject_unknown ~context:"[[mount]]" table [ "host"; "guest"; "mode" ];
  let host = as_string "mount.host" (require table "host" "[[mount]]") in
  if host = "" then fail "mount.host must not be empty";
  (* Read-only unless written out: write access is the grant that matters. *)
  let mode =
    match find table "mode" with
    | None -> Read_only
    | Some value -> (
        match as_string "mount.mode" value with
        | "ro" -> Read_only
        | "rw" -> Read_write
        | "clone" -> Clone
        | other ->
            fail
              (Printf.sprintf "unknown mount mode %s (expected ro, rw or clone)"
                 (Filename.quote other)))
  in
  (* Only a clone mount can leave the guest path out: it has a natural one. *)
  let guest =
    match (find table "guest", mode) with
    | Some value, _ -> as_string "mount.guest" value
    | None, Clone ->
        let name = clone_name { host; guest = ""; mode } in
        validate_clone_name name;
        "/src/" ^ name
    | None, _ -> as_string "mount.guest" (require table "guest" "[[mount]]")
  in
  if mode = Clone then validate_clone_name (clone_name { host; guest; mode });
  let guest = validate_guest_path guest in
  { host; guest; mode }

(* Nested guest mounts are refused until their semantics are qualified on the
   pinned runtime: which one wins, and whether a read-only inner mount really
   holds under a writable outer one. *)
let parse_mounts = function
  | None -> []
  | Some (Otoml.TomlTableArray tables) | Some (Otoml.TomlArray tables) ->
      let mounts = List.map parse_mount tables in
      List.iteri
        (fun i a ->
          List.iteri
            (fun j b ->
              if i < j && (is_within ~ancestor:a.guest b.guest || is_within ~ancestor:b.guest a.guest)
              then
                fail
                  (Printf.sprintf "mount guest paths %s and %s overlap" (Filename.quote a.guest)
                     (Filename.quote b.guest)))
            mounts)
        mounts;
      mounts
  | Some _ -> fail "mount must be an array of tables ([[mount]])"

let sub_table root key context =
  match find root key with
  | Some (Otoml.TomlTable _ as table) | Some (Otoml.TomlInlineTable _ as table) -> table
  | Some _ -> fail (Printf.sprintf "[%s] must be a table" key)
  | None -> fail (Printf.sprintf "missing table [%s] in %s" key context)

let parse ~path root =
  reject_unknown ~context:"the declaration" root
    [ "name"; "image"; "provision"; "resources"; "network"; "services"; "ssh";
      "mount"; "credentials" ];
  let name_value = as_string "name" (require root "name" "the declaration") in
  let name =
    match Workbench_name.of_string name_value with
    | Ok name -> name
    | Error reason ->
        fail (Printf.sprintf "invalid workbench name: %s" (Workbench_name.error_reason reason))
  in
  let image = parse_image (require root "image" "the declaration") in
  let resources = parse_resources (sub_table root "resources" "the declaration") in
  let network = parse_network (sub_table root "network" "the declaration") in
  (* Relative to the declaration, so a checkout can move without editing it. *)
  let provision =
    Option.map
      (fun value ->
        let script = as_string "provision" value in
        if script = "" then fail "provision must not be empty";
        if Filename.is_relative script then Filename.concat (Filename.dirname path) script
        else script)
      (find root "provision")
  in
  (* Provisioning installs packages, so it needs the network; a sealed
     workbench has none, and failing at parse beats failing at create. *)
  if provision <> None && network = Sealed then
    fail "provision needs a network, but this workbench is sealed";
  let herdr_enabled =
    match find root "services" with Some table -> parse_services table | None -> false
  in
  let ssh =
    match find root "ssh" with Some table -> parse_ssh table | None -> Disabled
  in
  let mounts = parse_mounts (find root "mount") in
  (* The credential table is carried through unparsed: each provider module
     owns its own schema, and Declaration should not have to know them all. *)
  let github_credential =
    match find root "credentials" with
    | Some table -> (
        reject_unknown ~context:"[credentials]" table [ "github" ];
        match find table "github" with Some github -> Some github | None -> None)
    | None -> None
  in
  {
    path; name; image; provision; resources; network; ssh; herdr_enabled; mounts;
    github_credential;
  }

let load path =
  if not (Sys.file_exists path) then Error (Ade_error.Declaration_not_found { path })
  else
    match Otoml.Parser.from_file_result path with
    | Error reason -> Error (Ade_error.Declaration_invalid { path; reason })
    | Ok root -> (
        match parse ~path root with
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
  line "image" (image_digest d);
  line "provision" (Option.value d.provision ~default:"");
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
  line "herdr" (string_of_bool d.herdr_enabled);
  (* Declaration order is not meaningful, so mounts are sorted by guest path. *)
  List.iter
    (fun mount ->
      line "mount"
        (Printf.sprintf "%s:%s:%s" mount.host mount.guest
           (match mount.mode with Read_only -> "ro" | Read_write -> "rw" | Clone -> "clone")))
    (List.sort (fun a b -> String.compare a.guest b.guest) d.mounts);
  Buffer.contents buffer

let digest_hex d = Digestif.SHA256.(digest_string (canonical d) |> to_hex)
