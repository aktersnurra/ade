let post ?runner ?(curl = "/usr/bin/curl") ~url ~bearer ~body () =
  let runner = match runner with Some r -> r | None -> Process_runner.run in
  (* The bearer token goes in via @- (stdin) rather than -H on the command
     line, so it never appears in argv where another local process could read
     it from the process table.

     -w writes the status after the body so both come back on stdout; -s and
     -S keep curl quiet except for real errors. *)
  let request =
    {
      Process_runner.executable = curl;
      argv =
        [
          "--silent"; "--show-error";
          "--request"; "POST";
          "--header"; "Accept: application/vnd.github+json";
          "--header"; "X-GitHub-Api-Version: 2022-11-28";
          "--header"; "@-";
          (* The body is the requested scope: repository names and
             permission levels. It is not secret, so argv is acceptable;
             stdin is already carrying the bearer header. *)
          "--header"; "Content-Type: application/json";
          "--data-binary"; body;
          "--write-out"; "\n%{http_code}";
          url;
        ];
      env =
        [ ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin") ];
      stdin = Some ("Authorization: Bearer " ^ bearer);
      stdio = Process_runner.Capture;
    }
  in
  match runner request with
  | Error error -> Error (Ade_error.to_string error)
  | Ok { Process_runner.status; stdout; stderr } ->
      if status <> 0 then
        Error (Printf.sprintf "curl exited with %d: %s" status (String.trim stderr))
      else
        (* The status code is the last line; everything before it is the body. *)
        let trimmed = String.trim stdout in
        match String.rindex_opt trimmed '\n' with
        | None -> (
            match int_of_string_opt trimmed with
            | Some code -> Ok (code, "")
            | None -> Error "curl produced no status code")
        | Some at -> (
            let body = String.sub trimmed 0 at in
            let code =
              String.sub trimmed (at + 1) (String.length trimmed - at - 1)
            in
            match int_of_string_opt (String.trim code) with
            | Some code -> Ok (code, body)
            | None -> Error ("unreadable status code from curl: " ^ code))
