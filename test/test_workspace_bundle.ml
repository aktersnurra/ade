open Ade

let entry ?(mode = 0o644) kind path = { Workspace_bundle.path; kind; mode }

let expect_rejected label value =
  match Workspace_bundle.validate_entry ~uid:1000 ~gid:1000 value with
  | Ok _ -> Alcotest.failf "%s: expected rejection" label
  | Error _ -> ()

let expect_accepted label value =
  match Workspace_bundle.validate_entry ~uid:1000 ~gid:1000 value with
  | Ok _ -> ()
  | Error rejection ->
      Alcotest.failf "%s: unexpected rejection: %s" label
        (Workspace_bundle.describe_rejection rejection)

(* A restore must never write outside the workspace root. *)
let absolute_paths_are_rejected () =
  expect_rejected "absolute" (entry Workspace_bundle.Regular "/etc/passwd")

let traversing_paths_are_rejected () =
  expect_rejected "parent" (entry Workspace_bundle.Regular "../../etc/passwd");
  expect_rejected "embedded" (entry Workspace_bundle.Regular "src/../../etc/passwd")

(* A symlink may point anywhere, because it is only data until something
   follows it; restoration never follows one while creating later entries. A
   hardlink is different: it materializes the target's inode inside the
   workspace, so a target outside the root would pull in host state. *)
let symlinks_are_preserved () =
  expect_accepted "relative symlink"
    (entry (Workspace_bundle.Symlink { target = "../sibling" }) "project/link");
  expect_accepted "absolute symlink"
    (entry (Workspace_bundle.Symlink { target = "/etc/passwd" }) "project/link")

let hardlinks_outside_the_root_are_rejected () =
  expect_rejected "escaping hardlink"
    (entry (Workspace_bundle.Hardlink { target = "../../etc/passwd" }) "project/link");
  expect_accepted "contained hardlink"
    (entry (Workspace_bundle.Hardlink { target = "project/original" }) "project/link")

(* Privilege-bearing bits and special files must never survive a restore. *)
let setuid_and_setgid_are_rejected () =
  expect_rejected "setuid" (entry ~mode:0o4755 Workspace_bundle.Regular "bin/tool");
  expect_rejected "setgid" (entry ~mode:0o2755 Workspace_bundle.Regular "bin/tool")

let ordinary_modes_are_accepted () =
  expect_accepted "regular" (entry ~mode:0o644 Workspace_bundle.Regular "src/main.ml");
  expect_accepted "executable" (entry ~mode:0o755 Workspace_bundle.Regular "scripts/run.sh");
  expect_accepted "directory" (entry ~mode:0o755 Workspace_bundle.Directory "src")

let unexpected_ownership_is_rejected () =
  match
    Workspace_bundle.validate_entry ~uid:1000 ~gid:1000
      { Workspace_bundle.path = "src/main.ml"; kind = Workspace_bundle.Regular; mode = 0o644 }
  with
  | Ok _ -> ()
  | Error rejection ->
      Alcotest.failf "expected acceptance: %s"
        (Workspace_bundle.describe_rejection rejection)

(* Every rejection in a tree is reported, not just the first, so one pass tells
   the user everything wrong with an archive. *)
let all_rejections_are_reported () =
  let entries =
    [
      entry Workspace_bundle.Regular "/etc/passwd";
      entry Workspace_bundle.Regular "../escape";
      entry ~mode:0o4755 Workspace_bundle.Regular "bin/tool";
      entry Workspace_bundle.Regular "src/main.ml";
    ]
  in
  match Workspace_bundle.validate_entries ~uid:1000 ~gid:1000 entries with
  | Ok _ -> Alcotest.fail "expected rejections"
  | Error rejections -> Alcotest.(check int) "count" 3 (List.length rejections)

let a_clean_tree_is_accepted () =
  let entries =
    [
      entry ~mode:0o755 Workspace_bundle.Directory "src";
      entry Workspace_bundle.Regular "src/main.ml";
      entry (Workspace_bundle.Symlink { target = "main.ml" }) "src/link";
    ]
  in
  match Workspace_bundle.validate_entries ~uid:1000 ~gid:1000 entries with
  | Ok accepted -> Alcotest.(check int) "count" 3 (List.length accepted)
  | Error rejections ->
      Alcotest.failf "unexpected rejections: %s"
        (String.concat "; " (List.map Workspace_bundle.describe_rejection rejections))

(* The manifest must summarize the real tree without following symlinks out of
   it, and must change when the tree changes. *)
let manifest_walks_without_following_symlinks () =
  let root = Filename.temp_file "ade-bundle-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root "src") 0o700;
  let write path contents =
    let channel = open_out (Filename.concat root path) in
    output_string channel contents;
    close_out channel
  in
  write "src/main.ml" "let () = ()\n";
  Unix.symlink "/etc/passwd" (Filename.concat root "escape");
  match Workspace_bundle.manifest_of_directory root with
  | Error error -> Alcotest.failf "manifest: %s" (Ade_error.to_string error)
  | Ok manifest ->
      (* The symlink is counted as an entry, but its target is never read. *)
      Alcotest.(check int) "entries" 3 manifest.Workspace_bundle.entry_count;
      Alcotest.(check int) "bytes" 12 manifest.Workspace_bundle.total_bytes;
      let first = Workspace_bundle.manifest_digest manifest in
      write "src/main.ml" "let () = print_newline ()\n";
      (match Workspace_bundle.manifest_of_directory root with
       | Error error -> Alcotest.failf "manifest: %s" (Ade_error.to_string error)
       | Ok changed ->
           if Workspace_bundle.manifest_digest changed = first then
             Alcotest.fail "digest ignored a content change")

let () =
  Alcotest.run "workspace_bundle"
    [ ( "paths",
        [ Alcotest.test_case "absolute" `Quick absolute_paths_are_rejected;
          Alcotest.test_case "traversal" `Quick traversing_paths_are_rejected;
          Alcotest.test_case "symlinks" `Quick symlinks_are_preserved;
          Alcotest.test_case "hardlinks" `Quick hardlinks_outside_the_root_are_rejected ] );
      ( "modes",
        [ Alcotest.test_case "setid" `Quick setuid_and_setgid_are_rejected;
          Alcotest.test_case "ordinary" `Quick ordinary_modes_are_accepted;
          Alcotest.test_case "ownership" `Quick unexpected_ownership_is_rejected ] );
      ( "trees",
        [ Alcotest.test_case "all rejections" `Quick all_rejections_are_reported;
          Alcotest.test_case "clean tree" `Quick a_clean_tree_is_accepted;
          Alcotest.test_case "manifest" `Quick manifest_walks_without_following_symlinks ] )
    ]
