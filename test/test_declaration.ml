open Ade

let write_temp contents =
  let path = Filename.temp_file "ade-decl-" ".toml" in
  let channel = open_out path in
  output_string channel contents;
  close_out channel;
  path

let valid_toml =
  {|
name = "work"
image = "docker.io/library/ade-workstation@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[resources]
cpus = 4
memory_mib = 8192
overlay_gib = 32
workspace_gib = 128

[network]
posture = "allowlisted"
hosts = ["github.com", "api.github.com"]
cidrs = ["10.0.0.0/8"]

[services]
herdr = true

[ssh]
mode = "dedicated_agent"
key_ref = "keychain:ade-work-ssh"

|}

let loads_valid () =
  let path = write_temp valid_toml in
  match Declaration.load path with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check string) "name" "work"
        (Workbench_name.to_string (Declaration.name declaration));
      (match Declaration.network declaration with
       | Declaration.Allowlisted { hosts; cidrs } ->
           Alcotest.(check (list string)) "hosts" [ "github.com"; "api.github.com" ] hosts;
           Alcotest.(check (list string)) "cidrs" [ "10.0.0.0/8" ] cidrs
       | _ -> Alcotest.fail "expected allowlisted network")

let rejects reason_fragment contents () =
  let path = write_temp contents in
  match Declaration.load path with
  | Ok _ -> Alcotest.failf "expected rejection containing %S" reason_fragment
  | Error error ->
      let message = Ade_error.to_string error in
      let contains haystack needle =
        let hl = String.length haystack and nl = String.length needle in
        let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
        nl = 0 || scan 0
      in
      if not (contains message reason_fragment) then
        Alcotest.failf "expected %S in %S" reason_fragment message

let missing_file () =
  match Declaration.load "/nonexistent/ade/work.toml" with
  | Ok _ -> Alcotest.fail "expected missing file to be rejected"
  | Error (Ade_error.Declaration_not_found _) -> ()
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)

let replace_line ~find ~replace contents =
  String.split_on_char '\n' contents
  |> List.map (fun line -> if line = find then replace else line)
  |> String.concat "\n"

let digest_is_stable_and_sensitive () =
  let path = write_temp valid_toml in
  let load path =
    match Declaration.load path with
    | Ok declaration -> declaration
    | Error error -> Alcotest.failf "load: %s" (Ade_error.to_string error)
  in
  let first = Declaration.digest_hex (load path) in
  let second = Declaration.digest_hex (load (write_temp valid_toml)) in
  Alcotest.(check string) "stable across identical files" first second;
  (* Reordering an order-insensitive list must not change the digest. *)
  let reordered =
    replace_line
      ~find:{|hosts = ["github.com", "api.github.com"]|}
      ~replace:{|hosts = ["api.github.com", "github.com"]|}
      valid_toml
  in
  let reordered_digest = Declaration.digest_hex (load (write_temp reordered)) in
  Alcotest.(check string) "order insensitive" first reordered_digest;
  (* A material change must change the digest. *)
  let changed =
    replace_line ~find:"cpus = 4" ~replace:"cpus = 8" valid_toml
  in
  let changed_digest = Declaration.digest_hex (load (write_temp changed)) in
  if changed_digest = first then Alcotest.fail "digest ignored a resource change"

(* The declarations shipped in this repository must always parse. *)
let shipped_declaration file expected_network () =
  let path = Filename.concat "../workbenches" file in
  match Declaration.load path with
  | Error error -> Alcotest.failf "%s: %s" file (Ade_error.to_string error)
  | Ok declaration ->
      let actual =
        match Declaration.network declaration with
        | Declaration.Sealed -> "sealed"
        | Declaration.Public -> "public"
        | Declaration.Allowlisted _ -> "allowlisted"
      in
      Alcotest.(check string) "network posture" expected_network actual

let with_mounts mounts = valid_toml ^ "\n" ^ mounts

let mount_table ?(mode = "") ~host ~guest () =
  Printf.sprintf "[[mount]]\nhost = %S\nguest = %S\n%s\n" host guest
    (if mode = "" then "" else Printf.sprintf "mode = %S" mode)

(* Undeclared means unmounted, and a declared mount is read-only by default. *)
let mounts_parse_in_order_and_default_read_only () =
  let path =
    write_temp
      (with_mounts
         (mount_table ~host:"~/code/a" ~guest:"/src/a" ()
         ^ mount_table ~host:"/data" ~guest:"/work/data" ~mode:"rw" ()))
  in
  match Declaration.load path with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration -> (
      match Declaration.mounts declaration with
      | [ a; b ] ->
          Alcotest.(check string) "first host" "~/code/a" a.Declaration.host;
          Alcotest.(check bool) "first read-only" true (a.Declaration.mode = Declaration.Read_only);
          Alcotest.(check string) "second guest" "/work/data" b.Declaration.guest;
          Alcotest.(check bool) "second writable" true (b.Declaration.mode = Declaration.Read_write)
      | mounts -> Alcotest.failf "expected two mounts, got %d" (List.length mounts))

let no_mounts_by_default () =
  match Declaration.load (write_temp valid_toml) with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check int) "no mounts" 0 (List.length (Declaration.mounts declaration))

(* A mount is part of what the machine is, so it must move the digest. *)
let mounts_change_the_digest () =
  let digest contents =
    match Declaration.load (write_temp contents) with
    | Ok declaration -> Declaration.digest_hex declaration
    | Error error -> Alcotest.failf "load: %s" (Ade_error.to_string error)
  in
  let ro = with_mounts (mount_table ~host:"/data" ~guest:"/work/data" ()) in
  let rw = with_mounts (mount_table ~host:"/data" ~guest:"/work/data" ~mode:"rw" ()) in
  Alcotest.(check bool) "unmounted differs" false (digest valid_toml = digest ro);
  Alcotest.(check bool) "mode differs" false (digest ro = digest rw)

let load_ok contents =
  match Declaration.load (write_temp contents) with
  | Ok declaration -> declaration
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)

(* A clone mount is the safe way to hand over a repository: the guest gets it
   read-only and works in its own copy. Its guest path defaults from the
   repository's name, so the common case needs only the host path. *)
let clone_mount_defaults_its_guest_path () =
  let declaration =
    load_ok (with_mounts "[[mount]]\nhost = \"~/code/project-a/\"\nmode = \"clone\"\n")
  in
  match Declaration.mounts declaration with
  | [ mount ] ->
      Alcotest.(check bool) "clone" true (mount.Declaration.mode = Declaration.Clone);
      Alcotest.(check string) "guest" "/src/project-a" mount.Declaration.guest;
      Alcotest.(check string) "name" "project-a" (Declaration.clone_name mount)
  | mounts -> Alcotest.failf "expected one mount, got %d" (List.length mounts)

let clone_mount_may_name_its_guest_path () =
  let declaration =
    load_ok
      (with_mounts
         "[[mount]]\nhost = \"/code/a\"\nguest = \"/ref/a\"\nmode = \"clone\"\n")
  in
  match Declaration.mounts declaration with
  | [ mount ] -> Alcotest.(check string) "guest" "/ref/a" mount.Declaration.guest
  | _ -> Alcotest.fail "expected one mount"

(* The name becomes a file name in /outbox and a path in /workspace, so it is
   held to a conservative alphabet. *)
let clone_mount_names_are_conservative = fun host () ->
  rejects "clone"
    (with_mounts (Printf.sprintf "[[mount]]\nhost = %S\nmode = \"clone\"\n" host))
    ()

let only_clone_mounts_may_omit_the_guest_path () =
  rejects "guest"
    (with_mounts "[[mount]]\nhost = \"/code/a\"\nmode = \"ro\"\n") ()

let rejects_mount fragment ?mode ~guest () =
  rejects fragment (with_mounts (mount_table ?mode ~host:"/data" ~guest ())) ()

let provisioned ~posture ~hosts =
  let network =
    if hosts then {|posture = "allowlisted"
hosts = ["geo.mirror.pkgbuild.com"]|}
    else Printf.sprintf {|posture = "%s"|} posture
  in
  Printf.sprintf
    {|name = "work"
image = "docker.io/menci/archlinuxarm:base-devel"
provision = "../provision/arch.sh"

[resources]
cpus = 2
memory_mib = 2048
overlay_gib = 8
workspace_gib = 16

[network]
%s

|}
    network

(* A registry tag is accepted without a digest: the guest runs pacman -Syu, so
   pinning the base image would not pin what the agents actually run. *)
let image_without_digest_is_accepted () =
  let declaration = load_ok (provisioned ~posture:"" ~hosts:true) in
  match Declaration.image declaration with
  | Declaration.Registry { reference } ->
      Alcotest.(check string) "reference" "docker.io/menci/archlinuxarm:base-devel" reference
  | Declaration.Local_artifact _ -> Alcotest.fail "expected a registry image"

let provision_is_relative_to_the_declaration () =
  let path = write_temp (provisioned ~posture:"" ~hosts:true) in
  match Declaration.load path with
  | Error error -> Alcotest.failf "load: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check (option string)) "resolved"
        (Some (Filename.concat (Filename.dirname path) "../provision/arch.sh"))
        (Declaration.provision declaration)

let provision_is_optional () =
  Alcotest.(check (option string)) "none" None
    (Declaration.provision (load_ok valid_toml))

let provision_changes_the_digest () =
  Alcotest.(check bool) "differs" false
    (Declaration.digest_hex (load_ok (provisioned ~posture:"" ~hosts:true))
     = Declaration.digest_hex
         (load_ok
            (replace_line ~find:{|provision = "../provision/arch.sh"|}
               ~replace:{|provision = "../provision/other.sh"|}
               (provisioned ~posture:"" ~hosts:true))))

let () =
  Alcotest.run "declaration"
    [ ( "valid",
        [ Alcotest.test_case "loads" `Quick loads_valid;
          Alcotest.test_case "digest" `Quick digest_is_stable_and_sensitive ] );
      ( "invalid",
        [ Alcotest.test_case "missing file" `Quick missing_file;
          Alcotest.test_case "unknown key" `Quick
            (rejects "unknown" (valid_toml ^ "\nsurprise = true\n"));
          Alcotest.test_case "malformed digest" `Quick
            (rejects "digest"
               (replace_line
                  ~find:{|image = "docker.io/library/ade-workstation@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|}
                  ~replace:{|image = "docker.io/library/ade-workstation@sha256:abc"|}
                  valid_toml));
          Alcotest.test_case "sealed with provision" `Quick
            (rejects "provision"
               (provisioned ~posture:"sealed" ~hosts:false));
          Alcotest.test_case "sealed with hosts" `Quick
            (rejects "sealed"
               (replace_line ~find:{|posture = "allowlisted"|}
                  ~replace:{|posture = "sealed"|} valid_toml));
          Alcotest.test_case "malformed cidr" `Quick
            (rejects "CIDR"
               (replace_line ~find:{|cidrs = ["10.0.0.0/8"]|}
                  ~replace:{|cidrs = ["10.0.0.0/64"]|} valid_toml));
          Alcotest.test_case "bad name" `Quick
            (rejects "workbench name"
               (replace_line ~find:{|name = "work"|} ~replace:{|name = "work bench"|}
                  valid_toml)) ] );
      ( "image and provisioning",
        [ Alcotest.test_case "tag without digest" `Quick image_without_digest_is_accepted;
          Alcotest.test_case "provision path" `Quick provision_is_relative_to_the_declaration;
          Alcotest.test_case "no provision" `Quick provision_is_optional;
          Alcotest.test_case "provision moves the digest" `Quick provision_changes_the_digest ] );
      ( "clone mounts",
        [ Alcotest.test_case "default guest" `Quick clone_mount_defaults_its_guest_path;
          Alcotest.test_case "named guest" `Quick clone_mount_may_name_its_guest_path;
          Alcotest.test_case "space in name" `Quick (clone_mount_names_are_conservative "/code/my repo");
          Alcotest.test_case "dotdot" `Quick (clone_mount_names_are_conservative "/code/..");
          Alcotest.test_case "outbox reserved" `Quick (rejects_mount "reserved" ~guest:"/outbox");
          Alcotest.test_case "guest required otherwise" `Quick
            only_clone_mounts_may_omit_the_guest_path ] );
      ( "mounts",
        [ Alcotest.test_case "parse" `Quick mounts_parse_in_order_and_default_read_only;
          Alcotest.test_case "none by default" `Quick no_mounts_by_default;
          Alcotest.test_case "digest" `Quick mounts_change_the_digest;
          Alcotest.test_case "relative guest" `Quick
            (rejects_mount "absolute" ~guest:"src/a");
          Alcotest.test_case "guest root" `Quick (rejects_mount "guest root" ~guest:"/");
          Alcotest.test_case "not normal" `Quick
            (rejects_mount "normal form" ~guest:"/src/../etc");
          Alcotest.test_case "trailing slash" `Quick
            (rejects_mount "normal form" ~guest:"/src/a/");
          Alcotest.test_case "colon" `Quick (rejects_mount "':'" ~guest:"/src/a:b");
          Alcotest.test_case "inside workspace" `Quick
            (rejects_mount "reserved" ~guest:"/workspace/a");
          Alcotest.test_case "secrets" `Quick
            (rejects_mount "reserved" ~guest:"/run/ade/secrets");
          Alcotest.test_case "above maintenance" `Quick
            (rejects_mount "reserved" ~guest:"/mnt");
          Alcotest.test_case "unknown mode" `Quick
            (rejects_mount "mount mode" ~mode:"copy" ~guest:"/src/a");
          Alcotest.test_case "unknown key" `Quick
            (rejects "unknown key"
               (with_mounts "[[mount]]\nhost = \"/data\"\nguest = \"/d\"\nfollow = true\n"));
          Alcotest.test_case "missing guest" `Quick
            (rejects "guest" (with_mounts "[[mount]]\nhost = \"/data\"\n"));
          Alcotest.test_case "overlap" `Quick
            (rejects "overlap"
               (with_mounts
                  (mount_table ~host:"/a" ~guest:"/src" ()
                  ^ mount_table ~host:"/b" ~guest:"/src/b" ())));
          Alcotest.test_case "duplicate" `Quick
            (rejects "overlap"
               (with_mounts
                  (mount_table ~host:"/a" ~guest:"/src" ()
                  ^ mount_table ~host:"/b" ~guest:"/src" ()))) ] );
      ( "shipped",
        [ Alcotest.test_case "work" `Quick
            (shipped_declaration "work.toml" "allowlisted");
          Alcotest.test_case "personal" `Quick
            (shipped_declaration "personal.toml" "public");
          Alcotest.test_case "work-offline" `Quick
            (shipped_declaration "work-offline.toml" "sealed");
          Alcotest.test_case "work-cloud example" `Quick
            (shipped_declaration "work-cloud.toml.example" "allowlisted") ] )
    ]
