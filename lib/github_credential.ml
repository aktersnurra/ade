type config = {
  app_id : string;
  installation_id : string;
  private_key_path : string;
  repositories : string list;
  permissions : (string * string) list;
}

type error =
  | Missing_private_key of string
  | Invalid_config of string
  | Exchange_failed of { status : int; body : string }
  | Malformed_response of string

let describe_error = function
  | Missing_private_key path -> "the GitHub App private key is not readable at " ^ path
  | Invalid_config reason -> "invalid GitHub credential configuration: " ^ reason
  | Exchange_failed { status; body } ->
      Printf.sprintf "GitHub refused the token exchange with status %d: %s" status
        (String.trim body)
  | Malformed_response reason -> "unreadable GitHub response: " ^ reason

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
  let* private_key_path = string_field table "private_key_path" in
  let* repositories = string_list_field table "repositories" in
  let* permissions = pairs_field table "permissions" in
  Ok { app_id; installation_id; private_key_path; repositories; permissions }

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
  else if not (Sys.file_exists config.private_key_path) then
    Error (Missing_private_key config.private_key_path)
  else Ok ()

type http_post = url:string -> bearer:string -> (int * string, string) result

let token_url config =
  "https://api.github.com/app/installations/" ^ config.installation_id
  ^ "/access_tokens"

(* GitHub requires iat/exp inside a ten-minute window and iss set to the App ID.
   The clock is backdated slightly because GitHub rejects a JWT whose iat is in
   the future relative to its own clock. *)
let jwt_claims config ~now =
  Printf.sprintf {|{"iat":%.0f,"exp":%.0f,"iss":"%s"}|} (now -. 60.0) (now +. 540.0)
    config.app_id

(* GitHub returns an RFC 3339 expiry. Parsing only the fields needed keeps this
   free of a date library. *)
let parse_expiry text =
  try
    Scanf.sscanf text "%4d-%2d-%2dT%2d:%2d:%2dZ"
      (fun year month day hour minute second ->
        let tm =
          {
            Unix.tm_year = year - 1900;
            tm_mon = month - 1;
            tm_mday = day;
            tm_hour = hour;
            tm_min = minute;
            tm_sec = second;
            tm_wday = 0;
            tm_yday = 0;
            tm_isdst = false;
          }
        in
        (* timegm, not mktime: the value is UTC and must not be shifted by the
           host's local timezone. *)
        let epoch, _ = Unix.mktime tm in
        let offset = fst (Unix.mktime (Unix.gmtime 0.0)) in
        Some (epoch -. offset))
  with _ -> None

let exchange ~post config ~jwt ~now =
  match post ~url:(token_url config) ~bearer:jwt with
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
