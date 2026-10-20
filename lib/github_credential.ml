type config = {
  app_id : string;
  installation_id : string;
  private_key : Secret.t;
  repositories : string list;
  permissions : (string * string) list;
}

type error =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string
  | Signing_failed of string
  | Scope_exceeded of string

let describe_error = function
  | Missing_private_key path -> "the GitHub App private key is not readable at " ^ path
  | Invalid_config reason -> "invalid GitHub credential configuration: " ^ reason
  | Exchange_failed { status; body } ->
      Printf.sprintf "GitHub refused the token exchange with status %d: %s" status
        (String.trim body)
  | Malformed_response reason -> "unreadable GitHub response: " ^ reason
  | Signing_failed reason -> "could not sign the GitHub App JWT: " ^ reason
  | Scope_exceeded reason ->
      "GitHub issued a token broader than requested, so it was discarded: " ^ reason

let ( let* ) = Result.bind

let string_field table key =
  match table with
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> (
      match List.assoc_opt key pairs with
      | Some (Otoml.TomlString value) -> Ok value
      | Some _ -> Error (Invalid_config (key ^ " must be a string"))
      | None -> Error (Invalid_config ("missing " ^ key)))
  | _ -> Error (Invalid_config "expected a table")

let string_list_field table key =
  match table with
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> (
      match List.assoc_opt key pairs with
      | Some (Otoml.TomlArray values) ->
          List.fold_left
            (fun acc value ->
              let* acc = acc in
              match value with
              | Otoml.TomlString s -> Ok (s :: acc)
              | _ -> Error (Invalid_config (key ^ " must contain only strings")))
            (Ok []) values
          |> Result.map List.rev
      | Some _ -> Error (Invalid_config (key ^ " must be an array"))
      | None -> Ok [])
  | _ -> Error (Invalid_config "expected a table")

let pairs_field table key =
  match table with
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> (
      match List.assoc_opt key pairs with
      | Some (Otoml.TomlTable inner) | Some (Otoml.TomlInlineTable inner) ->
          List.fold_left
            (fun acc (name, value) ->
              let* acc = acc in
              match value with
              | Otoml.TomlString level -> Ok ((name, level) :: acc)
              | _ -> Error (Invalid_config ("permission " ^ name ^ " must be a string")))
            (Ok []) inner
          |> Result.map List.rev
      | Some _ -> Error (Invalid_config (key ^ " must be a table"))
      | None -> Ok [])
  | _ -> Error (Invalid_config "expected a table")

let load_config table =
  let* app_id = string_field table "app_id" in
  let* installation_id = string_field table "installation_id" in
  let* key_reference = string_field table "private_key_path" in
  let* private_key =
    Result.map_error (fun reason -> Invalid_config reason)
      (Secret.of_reference key_reference)
  in
  let* repositories = string_list_field table "repositories" in
  let* permissions = pairs_field table "permissions" in
  Ok { app_id; installation_id; private_key; repositories; permissions }

(* The token request names repositories without their owner: an installation
   belongs to one account, so every declared repository must be under it. *)
let repository_names config =
  let split full =
    match String.split_on_char '/' full with
    | [ owner; name ] when owner <> "" && name <> "" -> Ok (Some owner, name)
    | [ name ] when name <> "" -> Ok (None, name)
    | _ -> Error (Invalid_config ("malformed repository " ^ Filename.quote full))
  in
  let* parsed =
    List.fold_left
      (fun acc full ->
        let* acc = acc in
        let* entry = split full in
        Ok (entry :: acc))
      (Ok []) config.repositories
    |> Result.map List.rev
  in
  match List.sort_uniq String.compare (List.filter_map fst parsed) with
  | [] | [ _ ] -> Ok (List.map snd parsed)
  | owners ->
      Error
        (Invalid_config
           ("repositories span several owners (" ^ String.concat ", " owners
          ^ "); one installation covers one account"))

(* Write is the broadest level ADE will request. admin would let the token
   change the repository's own settings, which is not an agent's job. *)
let level_rank = function "read" -> Some 1 | "write" -> Some 2 | _ -> None

let valid_permission_name name =
  name <> "" && String.for_all (function 'a' .. 'z' | '_' -> true | _ -> false) name

(* A token with no declared repositories reaches every repository the App is
   installed on, which is exactly the blast radius the design tries to avoid. *)
let validate config =
  if config.app_id = "" then Error (Invalid_config "app_id is empty")
  else if config.installation_id = "" then
    Error (Invalid_config "installation_id is empty")
  else if config.repositories = [] then
    Error
      (Invalid_config
         "no repositories declared; the token would reach every repository the \
          App is installed on")
  else if config.permissions = [] then
    Error
      (Invalid_config
         "no permissions declared; the token would carry the App's full \
          installation authority")
  else
    let* _ = repository_names config in
    match
      List.find_opt
        (fun (name, level) -> not (valid_permission_name name && level_rank level <> None))
        config.permissions
    with
    | Some (name, level) ->
        Error
          (Invalid_config
             (Printf.sprintf "permission %s = %s; expected read or write" name
                (Filename.quote level)))
    | None -> Ok ()

type http_post =
  url:string -> bearer:string -> body:string -> (int * string, string) result

(* The scope travels in the request body. Without it GitHub issues a token
   with the installation's full authority, whatever the declaration says. *)
let request_body config =
  let* names = repository_names config in
  Ok
    (Yojson.Safe.to_string
       (`Assoc
         [
           ("repositories", `List (List.map (fun name -> `String name) names));
           ( "permissions",
             `Assoc (List.map (fun (name, level) -> (name, `String level)) config.permissions) );
         ]))

(* GitHub echoes the scope it actually granted. It is checked rather than
   trusted, so a request that was silently widened (an App or API change, a
   proxy rewriting the body) never reaches the guest. metadata:read is granted
   to every installation token and cannot be declined. *)
let check_granted_scope config json =
  let member name = Yojson.Safe.Util.member name json in
  let* () =
    match member "repository_selection" with
    | `String "selected" -> Ok ()
    | `String other -> Error (Scope_exceeded ("repository_selection is " ^ other))
    | _ -> Error (Scope_exceeded "the response does not state its repository selection")
  in
  let* names = repository_names config in
  let* () =
    match member "repositories" with
    | `List repositories -> (
        let granted =
          List.filter_map
            (fun repository ->
              match Yojson.Safe.Util.member "name" repository with
              | `String name -> Some name
              | _ -> None)
            repositories
        in
        match List.find_opt (fun name -> not (List.mem name names)) granted with
        | Some extra -> Error (Scope_exceeded ("granted undeclared repository " ^ extra))
        | None -> Ok ())
    | _ -> Error (Scope_exceeded "the response does not list its repositories")
  in
  match member "permissions" with
  | `Assoc granted -> (
      let exceeds (name, level) =
        match (level, List.assoc_opt name config.permissions) with
        | `String "read", _ when name = "metadata" -> false
        | `String level, Some requested -> (
            match (level_rank level, level_rank requested) with
            | Some got, Some asked -> got > asked
            | _ -> true)
        | _ -> true
      in
      match List.find_opt exceeds granted with
      | Some (name, level) ->
          Error
            (Scope_exceeded
               (Printf.sprintf "permission %s = %s was not requested" name
                  (Yojson.Safe.to_string level)))
      | None -> Ok ())
  | _ -> Error (Scope_exceeded "the response does not state its permissions")

let token_url config =
  "https://api.github.com/app/installations/" ^ config.installation_id
  ^ "/access_tokens"

(* GitHub requires iat/exp inside a ten-minute window and iss set to the App ID.
   The clock is backdated slightly because GitHub rejects a JWT whose iat is in
   the future relative to its own clock. *)
let jwt_claims config ~now =
  Printf.sprintf {|{"iat":%.0f,"exp":%.0f,"iss":"%s"}|} (now -. 60.0) (now +. 540.0)
    config.app_id

(* JWT uses base64url without padding: '+' and '/' become '-' and '_', and the
   '=' padding is dropped. Standard base64 would be rejected. *)
let base64url raw =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" in
  let buffer = Buffer.create ((String.length raw * 4 / 3) + 4) in
  let length = String.length raw in
  let rec encode i =
    if i >= length then ()
    else begin
      let b0 = Char.code raw.[i] in
      let b1 = if i + 1 < length then Char.code raw.[i + 1] else 0 in
      let b2 = if i + 2 < length then Char.code raw.[i + 2] else 0 in
      Buffer.add_char buffer alphabet.[b0 lsr 2];
      Buffer.add_char buffer alphabet.[((b0 land 0x03) lsl 4) lor (b1 lsr 4)];
      if i + 1 < length then
        Buffer.add_char buffer alphabet.[((b1 land 0x0f) lsl 2) lor (b2 lsr 6)];
      if i + 2 < length then Buffer.add_char buffer alphabet.[b2 land 0x3f];
      encode (i + 3)
    end
  in
  encode 0;
  Buffer.contents buffer

(* GitHub requires RS256. *)
let jwt_header = {|{"alg":"RS256","typ":"JWT"}|}

let signing_input config ~now =
  base64url jwt_header ^ "." ^ base64url (jwt_claims config ~now)

type signer = string -> (string, string) result

let openssl_signer ~runner ~openssl ~reader config input =
  (* The key is resolved inside the callback and handed to openssl on stdin. It
     is never an argument, and it never becomes a value this function returns.
     openssl reads the key from a path, so a keychain-sourced key is written to
     a private temporary file for the duration of the call. *)
  let signature = ref None in
  let outcome =
    Secret.with_value ~reader config.private_key ~f:(fun key_bytes ->
        let key_file = Filename.temp_file "ade-jwt-" ".pem" in
        let write () =
          let descriptor =
            Unix.openfile key_file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
          in
          let channel = Unix.out_channel_of_descr descriptor in
          output_string channel key_bytes;
          close_out channel
        in
        let cleanup () = try Sys.remove key_file with Sys_error _ -> () in
        write ();
        let request =
          {
            Process_runner.executable = openssl;
            argv = [ "dgst"; "-sha256"; "-sign"; key_file ];
            env = [ ("PATH", try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin") ];
            stdin = Some input;
            stdio = Process_runner.Capture;
          }
        in
        let result = runner request in
        cleanup ();
        match result with
        | Error error -> Error error
        | Ok { Process_runner.status = 0; stdout; _ } when stdout <> "" ->
            signature := Some stdout;
            Ok ()
        | Ok { Process_runner.status; stderr; _ } ->
            Error
              (Ade_error.Operation_refused
                 {
                   operation = "sign JWT";
                   reason =
                     Printf.sprintf "openssl exited with %d: %s" status
                       (String.trim stderr);
                 }))
  in
  match (outcome, !signature) with
  | Ok (), Some value -> Ok value
  | Ok (), None -> Error "openssl produced no signature"
  | Error error, _ -> Error (Ade_error.to_string error)

let sign_jwt ~signer config ~now =
  let input = signing_input config ~now in
  match signer input with
  | Error reason -> Error (Signing_failed reason)
  | Ok signature -> Ok (input ^ "." ^ base64url signature)

(* GitHub returns an RFC 3339 expiry. Parsing only the fields needed keeps this
   free of a date library. *)
(* GitHub returns an RFC 3339 UTC timestamp. The epoch is computed directly
   rather than through Unix.mktime, which interprets the fields in the host's
   local timezone; correcting for that afterwards is unreliable because mktime
   also normalizes tm_isdst. Days-since-epoch is exact and timezone-free. *)
let parse_expiry text =
  let days_from_civil year month day =
    (* Howard Hinnant's civil-from-days, inverted: shifts the year so leap-day
       handling falls at the end of the cycle. *)
    let year = if month <= 2 then year - 1 else year in
    let era = (if year >= 0 then year else year - 399) / 400 in
    let year_of_era = year - (era * 400) in
    let day_of_year =
      ((153 * (if month > 2 then month - 3 else month + 9)) + 2) / 5 + day - 1
    in
    let day_of_era =
      (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
    in
    (era * 146097) + day_of_era - 719468
  in
  try
    Scanf.sscanf text "%4d-%2d-%2dT%2d:%2d:%2dZ"
      (fun year month day hour minute second ->
        let days = days_from_civil year month day in
        Some
          (float_of_int
             (((days * 24 + hour) * 60 + minute) * 60 + second)))
  with _ -> None

let exchange ~post config ~jwt ~now =
  let* body = request_body config in
  match post ~url:(token_url config) ~bearer:jwt ~body with
  | Error reason -> Error (Malformed_response reason)
  | Ok (status, body) when status < 200 || status >= 300 ->
      Error (Exchange_failed { status; body })
  | Ok (_, body) -> (
      match Yojson.Safe.from_string body with
      | exception Yojson.Json_error reason -> Error (Malformed_response reason)
      | json -> (
          let member name = Yojson.Safe.Util.member name json in
          match member "token" with
          | `String value ->
              let* () = check_granted_scope config json in
              let expires_at =
                match member "expires_at" with
                | `String text -> (
                    match parse_expiry text with
                    | Some epoch -> epoch
                    (* GitHub documents a one-hour lifetime; if the timestamp
                       cannot be read, assume the shorter horizon rather than a
                       longer one. *)
                    | None -> now +. 3600.0)
                | _ -> now +. 3600.0
              in
              Ok { Provider.value; expires_at }
          | _ -> Error (Malformed_response "response has no token field")))
