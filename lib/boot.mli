(** Bringing a workbench up and down with the capabilities it declares.

    Starting a machine is more than [smolvm machine start]. A workbench with a
    dedicated SSH identity needs its own host agent before boot, because the
    runtime forwards the agent socket at start; and its declared credentials
    must be installed before anything in the guest depends on them.

    Every step is undone if a later one fails, so a failed start leaves the
    machine stopped and no agent running, and a retry starts clean. *)

type purpose =
  | Work
      (** A normal start: the declared identity is loaded into the agent and
          declared credentials are installed. *)
  | Maintenance
      (** A bounded window, such as provisioning, in a guest ADE does not trust.
          The agent socket exists, because the machine requires one, but holds
          no identity, and no credential is installed. *)

type services = {
  start_agent :
    name:Workbench_name.t ->
    mode:Ssh_agent.mode ->
    identity:Secret.t option ->
    (Ssh_agent.t, Ade_error.t) result;
  stop_agent : Ssh_agent.t -> (unit, Ade_error.t) result;
  install_credentials :
    smolvm:Smolvm.t -> name:Workbench_name.t -> Declaration.t -> (unit, Ade_error.t) result;
  start_proxy : Declaration.t -> (Egress_guard.binding option, Ade_error.t) result;
      (** Start the proxy and return its required host guard binding; [None]
          unless proxied. *)
  ensure_proxy : Declaration.t -> (unit, Ade_error.t) result;
      (** Restart a proxy that died under a running machine. *)
  stop_proxy : Workbench_name.t -> (unit, Ade_error.t) result;
}
(** The host-side effects, injectable so tests never start a real agent or
    contact GitHub. *)

val default_services : paths:State_paths.t -> services
(** Real ssh-agent, a GitHub App token when the declaration has a
    [[credentials.github]] table, and an Anthropic API key when it has
    [[credentials.anthropic]]. Installing into a running guest that already has
    a token adds the next generation, so the same service refreshes. *)

val start :
  services:services ->
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  name:Workbench_name.t ->
  purpose:purpose ->
  Declaration.t ->
  (unit, Ade_error.t) result
(** Start the stopped machine [name] configured by the declaration.

    [name] is passed separately from the declaration. *)

val stop :
  services:services ->
  smolvm:Smolvm.t ->
  paths:State_paths.t ->
  Workbench_name.t ->
  (unit, Ade_error.t) result
(** Stop the running machine, then its agent and proxy. *)

val release_agent :
  services:services -> paths:State_paths.t -> Workbench_name.t -> (unit, Ade_error.t) result
(** Stop and forget a recorded agent, if any. For a machine that stopped
    without ADE, or an earlier ADE process that died. *)

val release :
  services:services -> paths:State_paths.t -> Workbench_name.t -> (unit, Ade_error.t) result
(** {!release_agent}, and stop the workbench's proxy if one runs. *)
