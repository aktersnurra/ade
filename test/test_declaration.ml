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
        | Declaration.Proxied _ -> "proxied"
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

(* A repository is handed to the guest as a bundle, not a mount. Its name
   comes from the last part of the host path, so only that path is written. *)
let repo_takes_its_name_from_the_host_path () =
  let declaration = load_ok (with_mounts "[[repo]]\nhost = \"~/code/project-a/\"\n") in
  match Declaration.repos declaration with
  | [ repo ] ->
      Alcotest.(check string) "host" "~/code/project-a/" repo.Declaration.host;
      Alcotest.(check string) "name" "project-a" repo.Declaration.name
  | repos -> Alcotest.failf "expected one repo, got %d" (List.length repos)

(* The name becomes a file name in /inbox and /outbox and a path in
   /workspace, so it is held to a conservative alphabet. *)
let repo_names_are_conservative = fun host () ->
  rejects "repository name" (with_mounts (Printf.sprintf "[[repo]]\nhost = %S\n" host)) ()

let clone_mounts_point_at_repo_entries () =
  rejects "[[repo]]" (with_mounts "[[mount]]\nhost = \"/code/a\"\nmode = \"clone\"\n") ()

let repos_change_the_identity_but_not_the_creation_shape () =
  let plain = load_ok valid_toml in
  let with_repo = load_ok (with_mounts "[[repo]]\nhost = \"/code/a\"\n") in
  Alcotest.(check bool) "digest differs" false
    (Declaration.digest_hex plain = Declaration.digest_hex with_repo);
  Alcotest.(check bool) "shape unchanged" true
    (Declaration.creation_shape plain = Declaration.creation_shape with_repo)

(* SmolVM boots at most eight mounts and ADE takes two of them, so a seventh
   is refused here instead of the machine failing to boot. *)
let mounts n = List.init n (fun i ->
    mount_table ~host:(Printf.sprintf "/data/%d" i) ~guest:(Printf.sprintf "/work/%d" i) ())
  |> String.concat "\n"

let six_mounts_fit () = ignore (load_ok (with_mounts (mounts 6)))

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
      Alcotest.(check (list string)) "resolved"
        [ Filename.concat (Filename.dirname path) "../provision/arch.sh" ]
        (Declaration.provision declaration)

(* A list runs in the order written, each path resolved like a single one. *)
let provision_takes_a_list () =
  let path =
    write_temp
      (replace_line ~find:{|provision = "../provision/arch.sh"|}
         ~replace:{|provision = ["../provision/arch.sh", "/etc/ade/mine.sh"]|}
         (provisioned ~posture:"" ~hosts:true))
  in
  match Declaration.load path with
  | Error error -> Alcotest.failf "load: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check (list string)) "in order"
        [ Filename.concat (Filename.dirname path) "../provision/arch.sh"; "/etc/ade/mine.sh" ]
        (Declaration.provision declaration)

let provision_is_optional () =
  Alcotest.(check (list string)) "none" []
    (Declaration.provision (load_ok valid_toml))

let provision_changes_the_digest () =
  Alcotest.(check bool) "differs" false
    (Declaration.digest_hex (load_ok (provisioned ~posture:"" ~hosts:true))
     = Declaration.digest_hex
         (load_ok
            (replace_line ~find:{|provision = "../provision/arch.sh"|}
               ~replace:{|provision = "../provision/other.sh"|}
               (provisioned ~posture:"" ~hosts:true))))

let anthropic_key_ref_is_parsed () =
  let path =
    write_temp (valid_toml ^ "\n[credentials.anthropic]\napi_key_ref = \"pass:ade/work-anthropic\"\n")
  in
  match Declaration.load path with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check (option string)) "reference" (Some "pass:ade/work-anthropic")
        (Declaration.anthropic_api_key_ref declaration)

let anthropic_key_ref_is_optional () =
  match Declaration.load (write_temp valid_toml) with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration ->
      Alcotest.(check (option string)) "none" None
        (Declaration.anthropic_api_key_ref declaration)

let proxied_network =
  replace_line ~find:{|posture = "allowlisted"|} ~replace:{|posture = "proxied"
proxy = "127.0.0.1:3128"|}
    (replace_line ~find:{|cidrs = ["10.0.0.0/8"]|} ~replace:"" valid_toml)

let proxied_is_parsed () =
  match Declaration.load (write_temp proxied_network) with
  | Error error -> Alcotest.failf "expected success: %s" (Ade_error.to_string error)
  | Ok declaration -> (
      match Declaration.network declaration with
      | Declaration.Proxied { hosts; proxy; classifier } ->
          Alcotest.(check (list string)) "hosts" [ "github.com"; "api.github.com" ] hosts;
          Alcotest.(check string) "proxy" "127.0.0.1:3128" proxy;
          Alcotest.(check bool) "no classifier" true (classifier = None)
      | _ -> Alcotest.fail "expected proxied")

(* Only the proxy's address is fixed at creation; the hosts are not. *)
let proxied_hosts_are_not_drift () =
  let shape text =
    match Declaration.load (write_temp text) with
    | Ok declaration -> Declaration.creation_shape declaration
    | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  in
  let edited =
    replace_line ~find:{|hosts = ["github.com", "api.github.com"]|}
      ~replace:{|hosts = ["github.com"]|} proxied_network
  in
  Alcotest.(check bool) "same shape" true (shape proxied_network = shape edited)

let load_for_property text =
  let path = write_temp text in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> Declaration.load path)

let declaration_identity_tracks_credential_scope () =
  Hegel.run_hegel_test ~database_key:"declaration-credential-identity" (fun tc ->
      let repo = Hegel.draw ~label:"repository" tc
          (Hegel.Generators.text ~alphabet:"abcdefghijklmnopqrstuvwxyz" ~min_size:1 ()) in
      let with_repo repo = valid_toml ^ Printf.sprintf
          "\n[credentials.github]\napp_id = \"1\"\ninstallation_id = \"2\"\nprivate_key_path = \"file:/unused\"\nrepositories = [%S]\npermissions = { contents = \"read\" }\n"
          ("owner/" ^ repo) in
      let before = Result.get_ok (load_for_property (with_repo repo)) in
      let after = Result.get_ok (load_for_property (with_repo ("changed-" ^ repo))) in
      Hegel.require tc ~msg:"credential scope is part of declaration identity"
        (Declaration.digest_hex before <> Declaration.digest_hex after))

let allowlist_order_does_not_change_identity () =
  Hegel.run_hegel_test ~database_key:"declaration-order" (fun tc ->
      let hosts = Hegel.draw ~label:"hosts" tc
          (Hegel.Generators.lists (Hegel.Generators.text ~alphabet:"abcdefghijklmnopqrstuvwxyz" ~min_size:1 ()) ()) in
      let render hosts = replace_line ~find:{|hosts = ["github.com", "api.github.com"]|}
          ~replace:("hosts = " ^ Yojson.Safe.to_string (`List (List.map (fun host -> `String (host ^ ".example")) hosts)))
          valid_toml in
      let digest hosts = Declaration.digest_hex (Result.get_ok (load_for_property (render hosts))) in
      Hegel.require tc (digest hosts = digest (List.rev hosts)))

let repo_name_uniqueness_is_enforced () =
  Hegel.run_hegel_test ~database_key:"repo-names" (fun tc ->
      let names = Hegel.draw ~label:"repos" tc
          (Hegel.Generators.lists (Hegel.Generators.text ~alphabet:"ab" ~min_size:1 ()) ()) in
      let repos = List.mapi (fun i name ->
          Printf.sprintf "[[repo]]\nhost = %S\n" (Printf.sprintf "/source/%d/%s" i name)) names
                  |> String.concat "\n" in
      let result = load_for_property (with_mounts repos) in
      Hegel.require tc (Result.is_ok result =
        (List.length names = List.length (List.sort_uniq String.compare names))))

let () =
  Alcotest.run "declaration"
    [ ( "valid",
        [ Alcotest.test_case "credential identity property" `Quick declaration_identity_tracks_credential_scope;
          Alcotest.test_case "allowlist order property" `Quick allowlist_order_does_not_change_identity;
          Alcotest.test_case "repo name property" `Quick repo_name_uniqueness_is_enforced;
          Alcotest.test_case "loads" `Quick loads_valid;
          Alcotest.test_case "digest" `Quick digest_is_stable_and_sensitive ] );
      ( "invalid",
        [ Alcotest.test_case "credential schema" `Quick
            (rejects "credentials.github" (valid_toml ^ "\n[credentials.github]\ntypo = true\n"));
          Alcotest.test_case "missing file" `Quick missing_file;
          Alcotest.test_case "unknown key" `Quick
            (rejects "unknown" (valid_toml ^ "\nsurprise = true\n"));
          Alcotest.test_case "malformed digest" `Quick
            (rejects "digest"
               (replace_line
                  ~find:{|image = "docker.io/library/ade-workstation@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|}
                  ~replace:{|image = "docker.io/library/ade-workstation@sha256:abc"|}
                  valid_toml));
          Alcotest.test_case "empty provision list" `Quick
            (rejects "provision"
               (replace_line ~find:{|provision = "../provision/arch.sh"|}
                  ~replace:{|provision = []|}
                  (provisioned ~posture:"" ~hosts:true)));
          Alcotest.test_case "empty provision path" `Quick
            (rejects "provision"
               (replace_line ~find:{|provision = "../provision/arch.sh"|}
                  ~replace:{|provision = ["../provision/arch.sh", ""]|}
                  (provisioned ~posture:"" ~hosts:true)));
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
      ( "proxied",
        [ Alcotest.test_case "parsed" `Quick proxied_is_parsed;
          Alcotest.test_case "hosts not drift" `Quick proxied_hosts_are_not_drift;
          Alcotest.test_case "needs proxy" `Quick
            (rejects "proxy"
               (replace_line ~find:{|proxy = "127.0.0.1:3128"|} ~replace:"" proxied_network));
          Alcotest.test_case "bad proxy" `Quick
            (rejects "IPV4:PORT"
               (replace_line ~find:{|proxy = "127.0.0.1:3128"|} ~replace:{|proxy = "localhost"|}
                  proxied_network));
          Alcotest.test_case "no cidrs" `Quick
            (rejects "cidrs"
               (replace_line ~find:{|posture = "allowlisted"|} ~replace:{|posture = "proxied"
proxy = "127.0.0.1:3128"|} valid_toml));
          Alcotest.test_case "bad host" `Quick
            (rejects "network.hosts"
               (replace_line ~find:{|hosts = ["github.com", "api.github.com"]|}
                  ~replace:{|hosts = ["git hub.com"]|} proxied_network));
          Alcotest.test_case "proxy elsewhere" `Quick
            (rejects "only to a proxied"
               (replace_line ~find:{|cidrs = ["10.0.0.0/8"]|}
                  ~replace:{|cidrs = ["10.0.0.0/8"]
proxy = "127.0.0.1:3128"|} valid_toml));
          Alcotest.test_case "classifier needs key" `Quick
            (rejects "api_key_ref"
               (proxied_network ^ "\n[network.classifier]\nmodel = \"m\"\n")) ] );
      ( "anthropic",
        [ Alcotest.test_case "parsed" `Quick anthropic_key_ref_is_parsed;
          Alcotest.test_case "optional" `Quick anthropic_key_ref_is_optional;
          Alcotest.test_case "value instead of reference" `Quick
            (rejects "api_key"
               (valid_toml ^ "\n[credentials.anthropic]\napi_key = \"sk-ant-x\"\n"));
          Alcotest.test_case "empty" `Quick
            (rejects "must not be empty"
               (valid_toml ^ "\n[credentials.anthropic]\napi_key_ref = \"\"\n"));
          Alcotest.test_case "unknown provider" `Quick
            (rejects "openai"
               (valid_toml ^ "\n[credentials.openai]\napi_key_ref = \"pass:x\"\n")) ] );
      ( "image and provisioning",
        [ Alcotest.test_case "tag without digest" `Quick image_without_digest_is_accepted;
          Alcotest.test_case "provision path" `Quick provision_is_relative_to_the_declaration;
          Alcotest.test_case "provision list" `Quick provision_takes_a_list;
          Alcotest.test_case "no provision" `Quick provision_is_optional;
          Alcotest.test_case "provision moves the digest" `Quick provision_changes_the_digest ] );
      ( "repositories",
        [ Alcotest.test_case "unique names" `Quick
            (rejects "duplicate repository"
               (with_mounts "[[repo]]\nhost = \"/one/repo\"\n[[repo]]\nhost = \"/two/repo\"\n"));
          Alcotest.test_case "name from host" `Quick repo_takes_its_name_from_the_host_path;
          Alcotest.test_case "space in name" `Quick (repo_names_are_conservative "/code/my repo");
          Alcotest.test_case "dotdot" `Quick (repo_names_are_conservative "/code/..");
          Alcotest.test_case "unknown key" `Quick
            (rejects "unknown key" (with_mounts "[[repo]]\nhost = \"/code/a\"\nmode = \"ro\"\n"));
          Alcotest.test_case "clone mode" `Quick clone_mounts_point_at_repo_entries;
          Alcotest.test_case "identity, not shape" `Quick
            repos_change_the_identity_but_not_the_creation_shape;
          Alcotest.test_case "outbox reserved" `Quick (rejects_mount "reserved" ~guest:"/outbox");
          Alcotest.test_case "inbox reserved" `Quick (rejects_mount "reserved" ~guest:"/inbox");
          Alcotest.test_case "guest required" `Quick
            (rejects "guest" (with_mounts "[[mount]]\nhost = \"/code/a\"\nmode = \"ro\"\n"));
          Alcotest.test_case "six mounts" `Quick six_mounts_fit;
          Alcotest.test_case "seven mounts" `Quick (rejects "at most 6" (with_mounts (mounts 7))) ] );
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
