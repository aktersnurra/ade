open Ade

(* Each case builds a throwaway home so the policy is exercised against real
   paths and real symlinks, the same way it runs on a host. *)
let fresh_home () =
  let base = Filename.temp_file "ade-home-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Unix.realpath base

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let policy home =
  Host_mount.default_policy ~home
    ~state_root:(Filename.concat home ".local/state/ade")
    ~declarations_dir:(Filename.concat home "ade/workbenches")

let mount ?(mode = Declaration.Read_only) host =
  { Declaration.host; guest = "/src/x"; mode }

let resolve home value = Host_mount.resolve (policy home) value

let accepted home value =
  match resolve home value with
  | Ok resolved -> resolved
  | Error error -> Alcotest.failf "expected acceptance: %s" (Ade_error.to_string error)

let refused fragment home value =
  match resolve home value with
  | Ok resolved -> Alcotest.failf "expected refusal, mounted %s" resolved.Host_mount.source
  | Error error ->
      let message = Ade_error.to_string error in
      let hl = String.length message and nl = String.length fragment in
      let rec scan i = i + nl <= hl && (String.sub message i nl = fragment || scan (i + 1)) in
      if not (scan 0) then Alcotest.failf "expected %S in %S" fragment message

let read_only_project_resolves () =
  let home = fresh_home () in
  let project = Filename.concat home "code/a" in
  mkdir_p (Filename.concat project ".git");
  let resolved = accepted home (mount "~/code/a") in
  Alcotest.(check string) "canonical source" project resolved.Host_mount.source;
  Alcotest.(check bool) "read-only" true resolved.Host_mount.read_only;
  Alcotest.(check string) "spec" (project ^ ":/src/x:ro") (Host_mount.volume_spec resolved)

let writable_data_resolves () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "scratch/data/nested");
  let resolved = accepted home (mount ~mode:Declaration.Read_write "~/scratch/data") in
  Alcotest.(check bool) "writable" false resolved.Host_mount.read_only;
  Alcotest.(check string) "spec"
    (Filename.concat home "scratch/data" ^ ":/src/x")
    (Host_mount.volume_spec resolved)

let home_is_refused () =
  let home = fresh_home () in
  refused "home directory" home (mount "~");
  refused "home directory" home (mount (Filename.dirname home));
  refused "home directory" home (mount "/")

let protected_paths_are_refused () =
  let home = fresh_home () in
  List.iter (fun dir -> mkdir_p (Filename.concat home dir))
    [ ".ssh"; ".config/jj"; ".local/state/ade"; "ade/workbenches"; "Library/Keychains" ];
  refused "protected" home (mount "~/.ssh");
  refused "protected" home (mount "~/.config/jj");
  refused "protected" home (mount "~/Library/Keychains");
  (* An ancestor of a protected path would expose it too. *)
  refused "protected" home (mount "~/.local");
  refused "protected" home (mount "~/ade")

(* The path that is checked must be the path that is mounted. *)
let symlinks_are_resolved_before_checking () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home ".ssh");
  mkdir_p (Filename.concat home "code");
  Unix.symlink (Filename.concat home ".ssh") (Filename.concat home "code/innocent");
  refused "protected" home (mount "~/code/innocent")

let writable_git_is_refused () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/a/.git/hooks");
  refused "version-control" home (mount ~mode:Declaration.Read_write "~/code/a")

let writable_jj_is_refused () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/b/.jj/repo");
  refused "version-control" home (mount ~mode:Declaration.Read_write "~/code/b")

(* A directory of repositories is as dangerous as one repository. *)
let nested_repository_is_refused () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/group/project/.git");
  refused "version-control" home (mount ~mode:Declaration.Read_write "~/code")

(* A worktree's .git is a file pointing elsewhere; rewriting it redirects the
   host's git to a directory the guest controls. *)
let git_file_is_refused () =
  let home = fresh_home () in
  let tree = Filename.concat home "code/worktree" in
  mkdir_p tree;
  let channel = open_out (Filename.concat tree ".git") in
  output_string channel "gitdir: /elsewhere\n";
  close_out channel;
  refused "version-control" home (mount ~mode:Declaration.Read_write "~/code/worktree")

let unusable_sources_are_refused () =
  let home = fresh_home () in
  refused "must be absolute" home (mount "code/a");
  refused "No such file" home (mount "~/missing");
  let file = Filename.concat home "notes.txt" in
  close_out (open_out file);
  refused "not a directory" home (mount "~/notes.txt")

let resolve_all_keeps_order_and_stops_at_first_refusal () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "a");
  mkdir_p (Filename.concat home "b");
  mkdir_p (Filename.concat home ".ssh");
  (match Host_mount.resolve_all (policy home) [ mount "~/b"; mount "~/a" ] with
   | Ok [ b; a ] ->
       Alcotest.(check string) "first" (Filename.concat home "b") b.Host_mount.source;
       Alcotest.(check string) "second" (Filename.concat home "a") a.Host_mount.source
   | Ok _ -> Alcotest.fail "expected two mounts"
   | Error error -> Alcotest.failf "unexpected: %s" (Ade_error.to_string error));
  match Host_mount.resolve_all (policy home) [ mount "~/a"; mount "~/.ssh" ] with
  | Ok _ -> Alcotest.fail "expected refusal"
  | Error _ -> ()

let () =
  Alcotest.run "host_mount"
    [
      ( "accepted",
        [ Alcotest.test_case "read-only project" `Quick read_only_project_resolves;
          Alcotest.test_case "writable data" `Quick writable_data_resolves;
          Alcotest.test_case "resolve all" `Quick
            resolve_all_keeps_order_and_stops_at_first_refusal ] );
      ( "refused",
        [ Alcotest.test_case "home" `Quick home_is_refused;
          Alcotest.test_case "protected" `Quick protected_paths_are_refused;
          Alcotest.test_case "symlink" `Quick symlinks_are_resolved_before_checking;
          Alcotest.test_case "writable git" `Quick writable_git_is_refused;
          Alcotest.test_case "writable jj" `Quick writable_jj_is_refused;
          Alcotest.test_case "nested repository" `Quick nested_repository_is_refused;
          Alcotest.test_case "git file" `Quick git_file_is_refused;
          Alcotest.test_case "unusable" `Quick unusable_sources_are_refused ] );
    ]
