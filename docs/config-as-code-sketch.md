# Config-as-code: a sketch

Not implemented. This exists so the pattern can be judged against the current
TOML declarations before anything is committed to.

The question it answers: **how does a secret get from the Keychain into a
signing call without ever being a `string` that could be logged?**

## The current shape, for comparison

```toml
[credentials.github]
app_id = "123456"
installation_id = "78901234"
private_key_path = "~/.config/ade/ade-personal.pem"
repositories = ["aktersnurra/gatekeep"]

[credentials.github.permissions]
contents = "write"
```

`Declaration.load` parses this once and rejects unknown keys, a malformed
CIDR, an unpinned image digest. After that a `Declaration.t` is known-good.

What it cannot do: stop `private_key_path`'s *contents* from being read into a
`string` somewhere and ending up in a log line. That property is currently
maintained by discipline plus tests.

## The same workbench as code

```ocaml
(* workbenches/personal.ml *)
open Ade_config

let personal =
  Workbench.make
    ~name:"personal"
    ~image:(Image.pinned "ade-nix-workstation" ~digest:"d8db3517...")
    ~resources:(Resources.make ~cpus:4 ~memory_mib:8192
                  ~overlay_gib:32 ~workspace_gib:128)
    ~network:Network.public
    ~services:(Services.make ~docker:true ~herdr:true)
    ~credentials:
      [ Github.app
          ~app_id:"123456"
          ~installation_id:"78901234"
          ~key:(Secret.keychain ~item:"ade-personal-app-key")
          ~repositories:(Repositories.non_empty [ "aktersnurra/gatekeep" ])
          ~permissions:[ Permission.contents `Write ]
      ]
    ~backup:(Backup.make ~directory:"~/ade-backups/personal" ~keep:3)
```

## How the secret actually flows

This is the part that is hard to picture. `Secret.t` is abstract: the
signature exposes no way to turn one into a `string`.

```ocaml
(* lib/secret.mli *)

type t
(** A credential that has not been read yet. Constructing one is cheap and
    safe: it names a source, it does not hold a value. *)

type source =
  | Keychain of { item : string }
  | File of { path : string }
  | Environment of { variable : string }

val keychain : item:string -> t
val file : path:string -> t

val describe : t -> string
(** For diagnostics: "keychain item ade-personal-app-key". Never the value.
    This is the ONLY function returning a string, and it cannot return the
    secret because the secret has not been read. *)

val with_value :
  t -> f:(string -> ('a, Ade_error.t) result) -> ('a, Ade_error.t) result
(** Read the secret, hand it to [f], and overwrite the buffer before
    returning. The value exists only inside [f]. It is never returned, so it
    cannot escape into a caller, a log, or an error message. *)
```

There is deliberately no `to_string`, no `value : t -> string`, no
`pp`. A caller that wants the bytes must accept them inside a closure that
returns something else.

### What that makes impossible

```ocaml
(* Does not compile: no accessor exists. *)
let leak secret = Printf.printf "key = %s" (Secret.value secret)

(* Does not compile: the string cannot escape the closure. *)
let steal secret =
  Secret.with_value secret ~f:(fun v -> Ok v)   (* type error: 'a = string
                                                   would escape its scope *)
```

The second case is the interesting one, and it needs a real mechanism rather
than a convention. Two options:

1. **Result type restriction.** Have `with_value` return
   `(unit, Ade_error.t) result` and require the caller to write its output
   somewhere explicit. Simple, and enough in practice.
2. **A phantom-typed wrapper.** `f` receives a `Secret.exposed` rather than a
   `string`, where `exposed` can only be consumed by
   `Process_runner.stdin_of_secret`. Stronger, and it makes "secrets travel on
   stdin, never argv" a type-level fact.

Option 2 is what makes this genuinely better than discipline: the current
guarantee that a credential never reaches argv rests on four tests and on me
having written `render_for_diagnostics` correctly. As a type, it stops being
something that can regress.

### At the call site

```ocaml
let sign_jwt_with config =
  Secret.with_value config.key ~f:(fun key_bytes ->
      (* key_bytes exists only here; openssl reads it on stdin *)
      Process_runner.run
        { executable = openssl
        ; argv = [ "dgst"; "-sha256"; "-sign"; "/dev/stdin" ]
        ; stdin = Some key_bytes
        ; env = [ ("PATH", path) ]
        ; stdio = Capture })
```

Compare with today, where `private_key_path` is a plain string that openssl
happens to read, and nothing at the type level distinguishes it from any other
string that could be printed.

## How the config is loaded

This is the other half people find unclear. There is no interpreter: the
declarations are compiled into the binary.

```ocaml
(* workbenches/registry.ml -- generated or hand-written *)
let all = [ Personal.personal; Work.work; Work_offline.offline ]
```

`ade status work` looks up `"work"` in that list. Changing `cpus` means
editing the file and rebuilding.

The alternative is compiling declarations to a plugin loaded at runtime, which
is worse here: it reintroduces a trusted-code-loading surface that the current
design deliberately avoids.

## What it does not do: keep secrets out of commits

Config-as-code does not help here, and is arguably slightly worse.

In TOML, a key pasted into the config looks wrong on sight, and secret scanners
are tuned for exactly that shape. In OCaml the file is a program, so an inline
value is syntactically natural:

```ocaml
~key:(Secret.keychain ~item:"ade-personal-app-key")            (* a reference *)
~key:(Secret.literal "-----BEGIN RSA PRIVATE KEY-----...")     (* also compiles *)
```

Both typecheck. The abstract type stops a secret being *printed*; it says
nothing about where the bytes came from. If a value-taking constructor exists,
someone reaches for it while debugging and commits it.

What actually prevents committed secrets, none of which needs config-as-code:

1. **No constructor accepts a value.** If `Secret.t` can only be built from
   `keychain`, `file` or `environment` -- with no `literal` and no `of_string`
   -- then a secret cannot be written into a configuration file at all, in
   either format. This is a property of the `Secret` module, not of the
   configuration language.
2. **A pre-commit secret scanner**, which is the mechanism most likely to catch
   a real mistake.
3. **Keeping the key outside the repository**, where it cannot be committed
   because it is not in the tree.

So the runtime property (a credential that cannot reach argv, a log or an
error message) comes from the abstract type. The commit-time property comes
from having no value-taking constructor, plus a scanner. They are separate
guarantees and neither requires config to be code.

## What it costs

- **Declarations stop being inert data.** Today the worst a malformed
  declaration does is fail to parse. As code, loading configuration means
  running code, and the trusted surface grows. The design is explicit that
  trusted configuration is reconstructed from the host declaration and never
  loaded from agent-writable storage.
- **Changing a workbench needs a rebuild.** Fine for one user; awkward for
  anything that generates configuration.
- **It contradicts V1 scope**: "V1 has no profile inheritance or configuration
  language beyond the fields the implementation consumes."
- **It does not, by itself, solve secret handling.** `Secret.keychain "item"`
  is a reference, exactly like `key_ref = "keychain:item"` in TOML. The
  leak-proofing comes from the abstract type, not from config being code.

## The separable conclusion

The two ideas are independent:

| | Keeps secrets out of the repo | Makes leaking a type error | Needs config-as-code |
| --- | --- | --- | --- |
| Keychain reference in TOML | yes | no | no |
| Abstract `Secret.t` | yes | yes | **no** |
| Config-as-code | yes | yes | yes |

`Secret.t` can be added to the existing library without touching the
configuration model. The TOML would carry `key_ref = "keychain:..."`, the
parser would produce a `Secret.t` instead of a `string`, and every call site
would be forced through `with_value`.

That yields the property worth having -- a credential that cannot be printed --
while declarations stay inert and V1 scope holds.

Config-as-code remains a reasonable V2 conversation about the whole
configuration model. It is not required to keep a `.pem` out of a chat window.
