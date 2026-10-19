(** The single boundary where ADE executes host processes.

    Commands are always built as an explicit argv. ADE never interpolates a
    workbench name, path, or credential into a shell string, so no value can be
    reinterpreted as shell syntax. *)

type stdio =
  | Capture  (** collect stdout and stderr for inspection *)
  | Inherit  (** hand the terminal to the child, for interactive attachment *)

type request = {
  executable : string;
  argv : string list;  (** arguments only; the executable is not repeated here *)
  env : (string * string) list;
  stdin : string option;
  stdio : stdio;
}

type output = { status : int; stdout : string; stderr : string }

type t = request -> (output, Ade_error.t) result
(** A runner. Tests substitute a fake for the real process boundary. *)

val find_executable : string -> string option
(** Search [PATH] for an executable. The runner needs an absolute path. *)

val run : t
val replace_process : request -> (unit, Ade_error.t) result

val render_for_diagnostics : request -> string
(** Executable and subcommand only. Later arguments and the environment may
    carry secret-bearing values and are never rendered. *)
