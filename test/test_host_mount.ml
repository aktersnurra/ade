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

(* A clone mount is read-only, so the git directory the writable rule guards is
   exactly what it exists to carry. It must be a git repository, because
   ade pull has nothing to bring back from anything else. *)
let clone_of_a_repository_resolves_read_only () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/a/.git");
  let resolved = accepted home (mount ~mode:Declaration.Clone "~/code/a") in
  Alcotest.(check bool) "read-only" true resolved.Host_mount.read_only

let clone_of_a_plain_directory_is_refused () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/plain");
  refused "git repository" home (mount ~mode:Declaration.Clone "~/code/plain")

(* The outbox is the one writable thing a clone workbench gets, and it is
   ADE's own directory, not a user path. *)
let clone_workbench_gets_an_outbox () =
  let home = fresh_home () in
  mkdir_p (Filename.concat home "code/a/.git");
  let declaration =
    (* Declarations live under the throwaway home, as they do for a user;
       the system temp directory would contain the home itself. *)
    mkdir_p (Filename.concat home "ade/workbenches");
    let path = Filename.concat home "ade/workbenches/work.toml" in
    Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel
          (Printf.sprintf
             {|name = "work"
image = "docker.io/menci/archlinuxarm:base-devel"

[resources]
cpus = 2
memory_mib = 2048
overlay_gib = 8
workspace_gib = 16

[network]
posture = "public"


[[mount]]
host = "%s/code/a"
mode = "clone"
|}
             home));
    match Declaration.load path with
    | Ok declaration -> declaration
    | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  in
  Unix.putenv "HOME" home;
  let paths = State_paths.make ~root:(Filename.concat home ".local/state/ade") () in
  match Host_mount.for_declaration ~paths declaration with
  | Error error -> Alcotest.failf "for_declaration: %s" (Ade_error.to_string error)
  | Ok [ repo; outbox ] ->
      Alcotest.(check string) "repo" "/src/a" repo.Host_mount.guest;
      Alcotest.(check string) "outbox guest" "/outbox" outbox.Host_mount.guest;
      Alcotest.(check bool) "outbox writable" false outbox.Host_mount.read_only;
      Alcotest.(check string) "outbox source"
        (State_paths.outbox_dir paths (Declaration.name declaration))
        outbox.Host_mount.source;
      Alcotest.(check bool) "resolution has no creation effects" false
        (Sys.file_exists outbox.Host_mount.source)
  | Ok mounts -> Alcotest.failf "expected repo and outbox, got %d" (List.length mounts)

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
      ( "clone",
        [ Alcotest.test_case "repository" `Quick clone_of_a_repository_resolves_read_only;
          Alcotest.test_case "plain directory" `Quick clone_of_a_plain_directory_is_refused;
          Alcotest.test_case "outbox" `Quick clone_workbench_gets_an_outbox ] );
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
