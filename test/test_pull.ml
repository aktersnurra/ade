open Ade

(* These tests run real git on the host: the property worth checking is what a
   fetch from a guest-written bundle does to a real repository. The guest side
   is simulated by a runner that bundles a clone sitting in the test's temp
   directory into the same outbox the guest would write to. *)

let git_exe = "/usr/bin/git"

let sh fmt =
  Printf.ksprintf
    (fun command ->
      if Sys.command (command ^ " >/dev/null 2>&1") <> 0 then
        Alcotest.failf "command failed: %s" command)
    fmt

let capture command =
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  ignore (Unix.close_process_in channel);
  String.trim output

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

type world = {
  home : string;
  host_repo : string;
  guest_clone : string;  (** stands in for /workspace/a inside the guest *)
  paths : State_paths.t;
  declaration : Declaration.t;
  mutable guest_commands : string list list;
}

let git_env = "GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t"

let make_world () =
  let base = Filename.temp_file "ade-pull-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let home = Unix.realpath base in
  Unix.putenv "HOME" home;
  let host_repo = Filename.concat home "code/a" in
  mkdir_p host_repo;
  sh "cd %s && git init -q -b main && %s git commit -q --allow-empty -m base" host_repo git_env;
  let guest_clone = Filename.concat home "guest-a" in
  sh "git clone -q %s %s" host_repo guest_clone;
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

[backup]
directory = "/tmp/b"
keep = 1

[[mount]]
host = "%s"
mode = "clone"
|}
           host_repo));
  let declaration =
    match Declaration.load path with
    | Ok declaration -> declaration
    | Error error -> Alcotest.failf "declaration: %s" (Ade_error.to_string error)
  in
  let paths = State_paths.make ~root:(Filename.concat home ".local/state/ade") () in
  {
    home; host_repo; guest_clone; paths; declaration; guest_commands = [];
  }

(* The guest command is `git -C /workspace/a bundle create /outbox/a.bundle
   --branches`. [mode] says what the simulated guest leaves in the outbox. *)
type guest = Honest | Fails | Symlink_to of string

let runner world guest request =
  let argv = request.Process_runner.argv in
  match List.rev argv with
  | "--branches" :: bundle :: "create" :: "bundle" :: _ :: "-C" :: "git" :: "--" :: _ ->
      world.guest_commands <- argv :: world.guest_commands;
      let outbox = State_paths.outbox_dir world.paths (Declaration.name world.declaration) in
      let target = Filename.concat outbox (Filename.basename bundle) in
      (match guest with
       | Honest ->
           sh "git -C %s bundle create %s --branches" world.guest_clone target;
           Ok { Process_runner.status = 0; stdout = ""; stderr = "" }
       | Fails ->
           Ok { Process_runner.status = 128; stdout = ""; stderr = "fatal: not a git repository" }
       | Symlink_to file ->
           Unix.symlink file target;
           Ok { Process_runner.status = 0; stdout = ""; stderr = "" })
  | _ -> Ok { Process_runner.status = 0; stdout = ""; stderr = "" }

let pull ~repo world guest =
  let smolvm =
    Smolvm.make ~executable:"/usr/bin/true" ~runner:(runner world guest)
  in
  Pull.run ~smolvm ~runner:Process_runner.run ~git:git_exe ~paths:world.paths
    world.declaration ~repo

let guest_commits_on_a_branch world =
  sh "cd %s && git checkout -q -b feature && %s git commit -q --allow-empty -m agent-work"
    world.guest_clone git_env

let rev world ref_name =
  capture (Printf.sprintf "git -C %s rev-parse --verify -q %s" world.host_repo ref_name)

(* The whole point: the agent's branch arrives as a remote-tracking ref, and
   nothing the user has checked out or named moves. *)
let a_pull_brings_branches_back_without_touching_the_host_branches () =
  let world = make_world () in
  guest_commits_on_a_branch world;
  let main_before = rev world "refs/heads/main" in
  (match pull world Honest ~repo:None with
   | Ok pulled -> Alcotest.(check (list string)) "pulled" [ "a" ] pulled
   | Error error -> Alcotest.failf "pull: %s" (Ade_error.to_string error));
  let agent_tip =
    capture (Printf.sprintf "git -C %s rev-parse feature" world.guest_clone)
  in
  Alcotest.(check string) "agent branch arrives" agent_tip
    (rev world "refs/remotes/agents/feature");
  Alcotest.(check string) "host main unmoved" main_before (rev world "refs/heads/main");
  Alcotest.(check string) "no local feature branch" "" (rev world "refs/heads/feature")

let a_named_repository_is_pulled () =
  let world = make_world () in
  guest_commits_on_a_branch world;
  match pull world Honest ~repo:(Some "a") with
  | Ok [ "a" ] -> ()
  | Ok _ -> Alcotest.fail "expected exactly a"
  | Error error -> Alcotest.failf "pull: %s" (Ade_error.to_string error)

let an_unknown_repository_is_refused () =
  let world = make_world () in
  match pull world Honest ~repo:(Some "nope") with
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error (Ade_error.Operation_refused _) ->
      Alcotest.(check int) "guest never asked" 0 (List.length world.guest_commands)
  | Error error -> Alcotest.failf "wrong error: %s" (Ade_error.to_string error)

let a_failing_guest_bundle_is_an_error () =
  let world = make_world () in
  match pull world Fails ~repo:None with
  | Ok _ -> Alcotest.fail "expected the failed bundle to be an error"
  | Error error ->
      let message = Ade_error.to_string error in
      let contains haystack needle =
        let hl = String.length haystack and nl = String.length needle in
        let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
        scan 0
      in
      Alcotest.(check bool) "carries the guest message" true
        (contains message "not a git repository")

(* The outbox is guest-written. A symlink there could point git at any file the
   host user can read, so only a regular file is ever opened. *)
let a_symlinked_bundle_is_refused () =
  let world = make_world () in
  let secret = Filename.concat world.home "secret" in
  Out_channel.with_open_bin secret (fun channel -> Out_channel.output_string channel "x");
  match pull world (Symlink_to secret) ~repo:None with
  | Ok _ -> Alcotest.fail "expected the symlink to be refused"
  | Error (Ade_error.Operation_refused _) -> ()
  | Error error -> Alcotest.failf "wrong error: %s" (Ade_error.to_string error)

(* Garbage that merely has the right name is not a bundle. *)
let a_file_that_is_not_a_bundle_is_refused () =
  let world = make_world () in
  let outbox = State_paths.outbox_dir world.paths (Declaration.name world.declaration) in
  mkdir_p outbox;
  let smolvm =
    Smolvm.make ~executable:"/usr/bin/true"
      ~runner:(fun request ->
        (match List.rev request.Process_runner.argv with
         | "--branches" :: bundle :: _ ->
             Out_channel.with_open_bin
               (Filename.concat outbox (Filename.basename bundle))
               (fun channel -> Out_channel.output_string channel "not a bundle")
         | _ -> ());
        Ok { Process_runner.status = 0; stdout = ""; stderr = "" })
  in
  match
    Pull.run ~smolvm ~runner:Process_runner.run ~git:git_exe ~paths:world.paths
      world.declaration ~repo:None
  with
  | Ok _ -> Alcotest.fail "expected a refusal"
  | Error _ ->
      Alcotest.(check string) "nothing fetched" "" (rev world "refs/remotes/agents/main")

let () =
  Alcotest.run "pull"
    [ ( "pull",
        [ Alcotest.test_case "branches arrive as agents/*" `Quick
            a_pull_brings_branches_back_without_touching_the_host_branches;
          Alcotest.test_case "named repository" `Quick a_named_repository_is_pulled;
          Alcotest.test_case "unknown repository" `Quick an_unknown_repository_is_refused;
          Alcotest.test_case "failing guest" `Quick a_failing_guest_bundle_is_an_error ] );
      ( "hostile outbox",
        [ Alcotest.test_case "symlink" `Quick a_symlinked_bundle_is_refused;
          Alcotest.test_case "not a bundle" `Quick a_file_that_is_not_a_bundle_is_refused ] ) ]
