open Ade

(* Host git is real here: what matters is what lands in the inbox and when.
   The guest is a recording fake, since its half is a shell script that runs
   inside the machine. *)

let git_exe = "/usr/bin/git"
let git_env = "GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t"

let sh fmt =
  Printf.ksprintf
    (fun command ->
      if Sys.command (command ^ " >/dev/null 2>&1") <> 0 then
        Alcotest.failf "command failed: %s" command)
    fmt

let rec mkdir_p path =
  if not (Sys.file_exists path) then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

type world = {
  home : string;
  paths : State_paths.t;
  name : Workbench_name.t;
  mutable guest : string list list;
  mutable guest_status : int;
  mutable bundles : int;
}

let make_world () =
  let base = Filename.temp_file "ade-sync-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let home = Unix.realpath base in
  { home; paths = State_paths.make ~root:(Filename.concat home "state") ();
    name = Result.get_ok (Workbench_name.of_string "work");
    guest = []; guest_status = 0; bundles = 0 }

let host_repo ?(commit = true) world name =
  let path = Filename.concat world.home ("code/" ^ name) in
  mkdir_p path;
  sh "git -C %s init -q -b main" path;
  if commit then sh "cd %s && %s git commit -q --allow-empty -m base" path git_env;
  path

let repo world name =
  let policy = Host_mount.default_policy ~home:world.home
      ~state_root:(Filename.concat world.home "state")
      ~declarations_dir:(Filename.concat world.home "decl") in
  match Host_mount.resolve_repo policy { Declaration.host = "~/code/" ^ name; name } with
  | Ok repo -> repo
  | Error error -> Alcotest.failf "resolve: %s" (Ade_error.to_string error)

let sync world repos =
  let smolvm = Smolvm.make ~executable:"/usr/bin/true" ~runner:(fun request ->
      world.guest <- request.Process_runner.argv :: world.guest;
      Ok { Process_runner.status = world.guest_status; stdout = ""; stderr = "boom" }) in
  let runner request =
    if List.mem "bundle" request.Process_runner.argv then world.bundles <- world.bundles + 1;
    Process_runner.run request in
  Repo_sync.sync ~smolvm ~runner ~git:git_exe ~paths:world.paths ~name:world.name repos

let expect_ok = function
  | Ok () -> ()
  | Error error -> Alcotest.failf "sync: %s" (Ade_error.to_string error)

let inbox world = State_paths.inbox_dir world.paths world.name
let inbox_files world = Sys.readdir (inbox world) |> Array.to_list |> List.sort String.compare

(* The guest is asked to clone or fetch each repository by name, as an
   argument to a fixed script, never spliced into it. *)
let guest_names world =
  List.rev_map (fun argv -> List.nth argv (List.length argv - 1)) world.guest

let a_repository_arrives_as_a_bundle_of_its_branches () =
  let world = make_world () in
  let source = host_repo world "a" in
  sh "cd %s && git branch feature" source;
  expect_ok (sync world [ repo world "a" ]);
  Alcotest.(check (list string)) "inbox" [ "a.bundle" ] (inbox_files world);
  let bundle = Filename.concat (inbox world) "a.bundle" in
  sh "git -C %s bundle verify %s" source bundle;
  let clone = Filename.concat world.home "guest-a" in
  sh "git clone -q %s %s" bundle clone;
  sh "git -C %s rev-parse --verify -q origin/feature" clone;
  Alcotest.(check (list string)) "guest asked" [ "a" ] (guest_names world);
  Alcotest.(check (list (pair string string))) "recorded" [ ("a", source) ]
    (Result.get_ok (Repo_sync.recorded ~paths:world.paths world.name))

let an_unchanged_repository_is_not_bundled_again () =
  let world = make_world () in
  let source = host_repo world "a" in
  expect_ok (sync world [ repo world "a" ]);
  expect_ok (sync world [ repo world "a" ]);
  Alcotest.(check int) "one bundle" 1 world.bundles;
  sh "cd %s && %s git commit -q --allow-empty -m more" source git_env;
  expect_ok (sync world [ repo world "a" ]);
  Alcotest.(check int) "rebundled after a commit" 2 world.bundles;
  Alcotest.(check int) "guest asked every time" 3 (List.length world.guest)

let a_dropped_repository_leaves_the_inbox () =
  let world = make_world () in
  ignore (host_repo world "a");
  ignore (host_repo world "b");
  expect_ok (sync world [ repo world "a"; repo world "b" ]);
  expect_ok (sync world [ repo world "b" ]);
  Alcotest.(check (list string)) "inbox" [ "b.bundle" ] (inbox_files world);
  Alcotest.(check (list string)) "recorded" [ "b" ]
    (List.map fst (Result.get_ok (Repo_sync.recorded ~paths:world.paths world.name)))

let an_empty_repository_is_skipped () =
  let world = make_world () in
  ignore (host_repo ~commit:false world "empty");
  ignore (host_repo world "a");
  expect_ok (sync world [ repo world "empty"; repo world "a" ]);
  Alcotest.(check (list string)) "inbox" [ "a.bundle" ] (inbox_files world);
  Alcotest.(check (list string)) "guest asked" [ "a" ] (guest_names world)

(* The guest's clone is the agents' own state: a failure there is reported,
   not fatal, or the user could not get into the workbench to fix it. *)
let a_guest_failure_is_not_fatal () =
  let world = make_world () in
  ignore (host_repo world "a");
  ignore (host_repo world "b");
  world.guest_status <- 1;
  expect_ok (sync world [ repo world "a"; repo world "b" ]);
  Alcotest.(check (list string)) "both attempted" [ "a"; "b" ] (guest_names world)

let a_host_failure_is_fatal () =
  let world = make_world () in
  let source = host_repo world "a" in
  let resolved = repo world "a" in
  sh "rm -rf %s/.git" source;
  match sync world [ resolved ] with
  | Ok () -> Alcotest.fail "expected the host failure to be an error"
  | Error _ -> Alcotest.(check int) "guest never asked" 0 (List.length world.guest)

let () =
  Alcotest.run "repo_sync"
    [ ( "sync",
        [ Alcotest.test_case "bundle of branches" `Quick a_repository_arrives_as_a_bundle_of_its_branches;
          Alcotest.test_case "unchanged" `Quick an_unchanged_repository_is_not_bundled_again;
          Alcotest.test_case "dropped" `Quick a_dropped_repository_leaves_the_inbox;
          Alcotest.test_case "empty" `Quick an_empty_repository_is_skipped;
          Alcotest.test_case "guest failure" `Quick a_guest_failure_is_not_fatal;
          Alcotest.test_case "host failure" `Quick a_host_failure_is_fatal ] ) ]
