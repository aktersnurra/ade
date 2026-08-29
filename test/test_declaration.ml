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
smolfile = "smolfiles/workstation.Smolfile"

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
docker = true
herdr = true

[ssh]
mode = "dedicated_agent"
key_ref = "keychain:ade-work-ssh"

[backup]
directory = "~/ade-backups/work"
keep = 5
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

let () =
  Alcotest.run "declaration"
    [ ( "valid",
        [ Alcotest.test_case "loads" `Quick loads_valid;
          Alcotest.test_case "digest" `Quick digest_is_stable_and_sensitive ] );
      ( "invalid",
        [ Alcotest.test_case "missing file" `Quick missing_file;
          Alcotest.test_case "unknown key" `Quick
            (rejects "unknown" (valid_toml ^ "\nsurprise = true\n"));
          Alcotest.test_case "missing digest" `Quick
            (rejects "digest"
               (replace_line
                  ~find:{|image = "docker.io/library/ade-workstation@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|}
                  ~replace:{|image = "docker.io/library/ade-workstation:latest"|}
                  valid_toml));
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
