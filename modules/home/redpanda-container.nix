# home-manager module: a local Redpanda cluster on Apple Container.
#
# Declares services.redpanda-container.* -- MasterPlan Integration Point 5, which
# docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md
# consumes. Renaming an option here means changing that plan in the same commit.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.redpanda-container;
  defaults = import ./defaults.nix { inherit pkgs; };

  # Everything the scripts read, resolved from options. Passing the whole set
  # rather than individual arguments keeps a future second instance a matter of
  # calling this with different values.
  scriptCfg = {
    inherit (cfg)
      package redpandaImage consoleImage platform enableConsole
      network brokerName consoleName volumeName nodeId labelPrefix
      internalHost hostAddress ports cpus memory stateDir
      readyTimeoutSeconds runtimeTimeoutSeconds;
    inherit (defaults) containerPorts dataDir brokerUid brokerGid;
  };

  scripts = import ./scripts.nix { inherit pkgs lib; cfg = scriptCfg; };
  scriptList = builtins.attrValues scripts;

  logDir = "${cfg.stateDir}/logs";
  label = "com.shinzui.redpanda";

  portsType = lib.types.submodule {
    options = {
      kafka = lib.mkOption {
        type = lib.types.port;
        default = defaults.ports.kafka;
        description = "Host port for the Kafka API (the broker's external listener).";
      };
      admin = lib.mkOption {
        type = lib.types.port;
        default = defaults.ports.admin;
        description = "Host port for the Admin API, which also serves the readiness endpoint.";
      };
      schemaRegistry = lib.mkOption {
        type = lib.types.port;
        default = defaults.ports.schemaRegistry;
        description = "Host port for the Schema Registry (external listener).";
      };
      proxy = lib.mkOption {
        type = lib.types.port;
        default = defaults.ports.proxy;
        description = "Host port for the HTTP Proxy, also called pandaproxy (external listener).";
      };
      console = lib.mkOption {
        type = lib.types.port;
        default = defaults.ports.console;
        description = "Host port for the Redpanda Console web UI.";
      };
    };
  };
in
{
  options.services.redpanda-container = {
    enable = lib.mkEnableOption "a local Redpanda cluster running on Apple Container";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaults.package;
      defaultText = lib.literalExpression "pkgs.container";
      description = ''
        The Apple Container package providing the `container` binary.

        Exposed as an option rather than pinned to `pkgs.container` because plain
        nixpkgs ships an older release than the one this is developed against; a
        consumer with an overlay that shadows `container` gets its version here.
      '';
    };

    redpandaImage = lib.mkOption {
      type = lib.types.str;
      default = defaults.redpandaImage;
      description = ''
        The Redpanda broker image.

        Defaults to the Docker Hub mirror rather than docker.redpanda.com, which
        rate-limited every attempt during development (persistent HTTP 429).
      '';
    };

    consoleImage = lib.mkOption {
      type = lib.types.str;
      default = defaults.consoleImage;
      description = "The Redpanda Console image.";
    };

    platform = lib.mkOption {
      type = lib.types.str;
      default = defaults.platform;
      description = ''
        Platform passed to `container run`.

        Both images are multi-arch and Apple Container selected the amd64 variant
        on an arm64 machine during development, which would silently run Redpanda
        under emulation. Setting this explicitly is not optional in practice.
      '';
    };

    enableConsole = lib.mkOption {
      type = lib.types.bool;
      default = defaults.enableConsole;
      description = "Whether to run Redpanda Console alongside the broker.";
    };

    network = lib.mkOption {
      type = lib.types.str;
      default = defaults.network;
      description = "Name of the Apple Container user-defined network the containers share.";
    };

    brokerName = lib.mkOption {
      type = lib.types.str;
      default = defaults.brokerName;
      description = "Container name for the Redpanda broker.";
    };

    consoleName = lib.mkOption {
      type = lib.types.str;
      default = defaults.consoleName;
      description = "Container name for Redpanda Console.";
    };

    volumeName = lib.mkOption {
      type = lib.types.str;
      default = defaults.volumeName;
      description = ''
        Name of the named volume holding the broker's data.

        Data lives on this volume rather than in the container's writable layer, so
        it survives the container being deleted and recreated.
      '';
    };

    nodeId = lib.mkOption {
      type = lib.types.int;
      default = defaults.nodeId;
      description = "Redpanda node id for the single broker.";
    };

    labelPrefix = lib.mkOption {
      type = lib.types.str;
      default = defaults.labelPrefix;
      description = ''
        Prefix for the labels applied to every container this module creates.

        Deliberately unlike `rpk container start`'s own labels so a Docker-based
        cluster and this one are never confused. `redpanda-purge` filters strictly
        on this prefix, which is what stops it deleting a container it did not create.
      '';
    };

    internalHost = lib.mkOption {
      type = lib.types.str;
      default = defaults.internalHost;
      description = ''
        The address the broker advertises to clients arriving on its internal
        listener -- in practice, Console.

        Apple Container has no container-to-container name resolution, so this name
        is made resolvable by generating a hosts file from the broker's actual IP
        and bind-mounting it over /etc/hosts in Console's container. Keep it equal
        to `brokerName` unless you have a reason not to.
      '';
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = defaults.hostAddress;
      description = ''
        The host address the container ports are published on, and the address the
        broker advertises to clients on the host.

        These two uses must agree, which is why they are one option: a Kafka client
        connects, asks for metadata, and then connects to whatever the broker
        advertised. Defaults to loopback so the cluster is not exposed off-machine.
      '';
    };

    ports = lib.mkOption {
      type = portsType;
      default = { };
      description = "Host ports for each published service.";
    };

    cpus = lib.mkOption {
      type = lib.types.int;
      default = defaults.cpus;
      description = "CPUs allocated to the broker container.";
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = defaults.memory;
      description = "Memory allocated to the broker container, as accepted by `container run -m`.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/redpanda";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.local/state/redpanda"'';
      description = ''
        Directory for this module's host-side state: the generated hosts file and,
        when autoStart is on, the launchd agent's logs.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install a launchd agent that brings the cluster up at login.

        When false the five commands are still installed; only the agent is omitted.
      '';
    };

    readyTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = defaults.readyTimeoutSeconds;
      description = ''
        How long `redpanda-up` waits for the broker's readiness endpoint before
        giving up and printing the broker's recent logs.
      '';
    };

    runtimeTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = defaults.runtimeTimeoutSeconds;
      description = ''
        How long to wait for Apple Container's own API server before failing.

        This is not a formality: the launchd agent can fire at login before
        container-apiserver is up, so the wait is what stops every login being a race.
      '';
    };

    scripts = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      readOnly = true;
      default = scriptList;
      defaultText = lib.literalExpression "the five redpanda-* wrapper scripts";
      description = "The generated wrapper scripts, exposed so consumers can reference them.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = scriptList;

    home.activation.redpanda-container-init =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "${cfg.stateDir}" "${logDir}"
      '';

    # Stop the agent and wait for its process to actually exit before
    # home-manager re-registers it. `launchctl bootout` returns before the process
    # is gone, and the following bootstrap then fails with I/O error (code 5).
    # Mirrors home.activation.victorialogs-stop-agents in the dotfiles repository.
    home.activation.redpanda-container-stop-agents =
      lib.mkIf cfg.autoStart (lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
        domain="gui/$(id -u)"
        newPlist="$newGenPath/LaunchAgents/${label}.plist"
        curPlist="$HOME/Library/LaunchAgents/${label}.plist"

        if cmp -s "$newPlist" "$curPlist"; then
          verboseEcho "${label} plist unchanged, skipping stop"
        elif /bin/launchctl print "$domain/${label}" &>/dev/null; then
          # awk-only (exits 0 on no match) plus `|| true`: a loaded-but-not-running
          # agent has no `pid = ` line, and grep exiting 1 would abort the switch
          # under home-manager's `set -euo pipefail`.
          pid=$(/bin/launchctl print "$domain/${label}" 2>/dev/null \
                | /usr/bin/awk '/[[:space:]]pid = /{print $NF; exit}') || true

          verboseEcho "Stopping ${label} (pid ''${pid:-unknown})..."
          /bin/launchctl bootout "$domain/${label}" 2>/dev/null || true

          if [ -n "$pid" ]; then
            while kill -0 "$pid" 2>/dev/null; do
              sleep 1
            done
          fi
        fi
      '');

    # A one-shot: it runs redpanda-up and exits. The long-running processes are the
    # containers, which Apple Container's own service supervises.
    #
    # KeepAlive is therefore NOT `true` -- that would restart a successfully exiting
    # script in a tight loop. `SuccessfulExit = false` gives the useful half: retry
    # if bring-up failed (the API server was not up yet, say), leave it alone if it
    # worked.
    launchd.agents.redpanda = lib.mkIf cfg.autoStart {
      enable = true;
      config = {
        Label = label;
        ProgramArguments = [ "${scripts.redpanda-up}/bin/redpanda-up" ];
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        ExitTimeOut = 120;
        StandardOutPath = "${logDir}/redpanda-up.stdout.log";
        StandardErrorPath = "${logDir}/redpanda-up.stderr.log";
      };
    };
  };
}
