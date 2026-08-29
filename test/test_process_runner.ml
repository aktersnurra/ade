open Ade

(* Arguments are passed as an explicit argv, never through a shell, so a value
   containing spaces or shell metacharacters stays exactly one argument. *)
let argument_with_spaces_stays_one_argument () =
  let script = Filename.temp_file "ade-argv-" ".sh" in
  let channel = open_out script in
  output_string channel "#!/bin/sh\nfor arg in \"$@\"; do echo \"[$arg]\"; done\n";
  close_out channel;
  Unix.chmod script 0o755;
  let request =
    {
      Process_runner.executable = script;
      argv = [ "one two"; "three; rm -rf /"; "$(whoami)" ];
      env = [ ("PATH", "/usr/bin:/bin") ];
      stdin = None;
      stdio = Process_runner.Capture;
    }
  in
  match Process_runner.run request with
  | Error error -> Alcotest.failf "run: %s" (Ade_error.to_string error)
  | Ok output ->
      Alcotest.(check string) "argv preserved"
        "[one two]\n[three; rm -rf /]\n[$(whoami)]\n" output.Process_runner.stdout

(* Diagnostics must never render later arguments or the environment, because
   both can carry credential values. *)
let diagnostics_omit_secret_bearing_values () =
  let request =
    {
      Process_runner.executable = "/usr/bin/true";
      argv = [ "machine"; "start"; "--token"; "s3cr3t-token-value" ];
      env = [ ("GITHUB_TOKEN", "another-secret") ];
      stdin = None;
      stdio = Process_runner.Capture;
    }
  in
  let rendered = Process_runner.render_for_diagnostics request in
  let contains needle =
    let hl = String.length rendered and nl = String.length needle in
    let rec scan i = i + nl <= hl && (String.sub rendered i nl = needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "no argument secret" false (contains "s3cr3t-token-value");
  Alcotest.(check bool) "no environment secret" false (contains "another-secret");
  Alcotest.(check bool) "keeps subcommand" true (contains "machine")

(* Secrets are handed to a child on stdin rather than argv. *)
let stdin_payload_reaches_the_child () =
  let request =
    {
      Process_runner.executable = "/bin/cat";
      argv = [];
      env = [ ("PATH", "/usr/bin:/bin") ];
      stdin = Some "generation-payload";
      stdio = Process_runner.Capture;
    }
  in
  match Process_runner.run request with
  | Error error -> Alcotest.failf "run: %s" (Ade_error.to_string error)
  | Ok output ->
      Alcotest.(check string) "stdin forwarded" "generation-payload"
        output.Process_runner.stdout

let nonzero_status_is_reported () =
  let request =
    {
      Process_runner.executable = "/usr/bin/false";
      argv = [];
      env = [ ("PATH", "/usr/bin:/bin") ];
      stdin = None;
      stdio = Process_runner.Capture;
    }
  in
  match Process_runner.run request with
  | Error error -> Alcotest.failf "run: %s" (Ade_error.to_string error)
  | Ok output -> Alcotest.(check int) "status" 1 output.Process_runner.status

let missing_executable_is_unavailable () =
  let request =
    {
      Process_runner.executable = "/nonexistent/ade/smolvm";
      argv = [];
      env = [];
      stdin = None;
      stdio = Process_runner.Capture;
    }
  in
  match Process_runner.run request with
  | Error (Ade_error.Runtime_unavailable _) -> ()
  | Error error -> Alcotest.failf "unexpected error: %s" (Ade_error.to_string error)
  | Ok _ -> Alcotest.fail "expected a missing executable to be reported"

(* The child environment is exactly what ADE declares; nothing is inherited. *)
let environment_is_not_inherited () =
  Unix.putenv "ADE_TEST_LEAKED" "leaked-value";
  let request =
    {
      Process_runner.executable = "/usr/bin/env";
      argv = [];
      env = [ ("PATH", "/usr/bin:/bin") ];
      stdin = None;
      stdio = Process_runner.Capture;
    }
  in
  match Process_runner.run request with
  | Error error -> Alcotest.failf "run: %s" (Ade_error.to_string error)
  | Ok output ->
      let stdout = output.Process_runner.stdout in
      let contains needle =
        let hl = String.length stdout and nl = String.length needle in
        let rec scan i = i + nl <= hl && (String.sub stdout i nl = needle || scan (i + 1)) in
        scan 0
      in
      Alcotest.(check bool) "host variable not inherited" false (contains "leaked-value")

let () =
  Alcotest.run "process_runner"
    [ ( "argv",
        [ Alcotest.test_case "spaces" `Quick argument_with_spaces_stays_one_argument;
          Alcotest.test_case "diagnostics" `Quick diagnostics_omit_secret_bearing_values ] );
      ( "streams",
        [ Alcotest.test_case "stdin" `Quick stdin_payload_reaches_the_child;
          Alcotest.test_case "status" `Quick nonzero_status_is_reported;
          Alcotest.test_case "environment" `Quick environment_is_not_inherited ] );
      ( "errors",
        [ Alcotest.test_case "missing executable" `Quick missing_executable_is_unavailable ] )
    ]
