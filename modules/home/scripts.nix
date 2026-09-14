# The five lifecycle wrappers.
#
# Built with pkgs.writeShellApplication, which sets `set -euo pipefail`, puts
# runtimeInputs on PATH so no store paths need interpolating at call sites, and
# runs shellcheck at build time.
#
# Every command these scripts issue was verified by hand first; the transcripts
# are in docs/spikes/1-apple-container-redpanda-findings.md. Where this file looks
# surprising -- the volume chown, the explicit --platform, the generated hosts
# file -- it is because the spike found the obvious version does not work.
{ pkgs, lib, cfg }:

let
  inherit (cfg) internalHost hostAddress labelPrefix;
  cp = cfg.containerPorts;

  container = "${cfg.package}/bin/container";

  # Console's configuration is entirely static -- it names the broker by the
  # internal host string and by container-side ports, none of which vary at
  # runtime -- so it is a store file rather than something generated at start.
  # Only the hosts file has to be generated, because only the IP is dynamic.
  consoleConfig = pkgs.writeText "redpanda-console-config.yaml" ''
    kafka:
      brokers: ["${internalHost}:${toString cp.kafkaInternal}"]
    schemaRegistry:
      enabled: true
      urls: ["http://${internalHost}:${toString cp.schemaRegistryInternal}"]
    redpanda:
      adminApi:
        enabled: true
        urls: ["http://${internalHost}:${toString cp.admin}"]
  '';

  runtimeInputs = [ cfg.package pkgs.jq pkgs.curl pkgs.coreutils ];

  # Prelude fragments, composed per script rather than shipped as one shared blob.
  # writeShellApplication runs shellcheck, which flags an unused variable as a
  # warning and fails the build -- so each script gets exactly the definitions it
  # uses and no more. Order within a script's list matters: hosts_file reads
  # state_dir, broker_ready reads ready_url.
  snippets = {
    state_dir = ''state_dir="${cfg.stateDir}"'';
    hosts_file = ''hosts_file="$state_dir/console-hosts"'';
    broker = ''broker="${cfg.brokerName}"'';
    console = ''console="${cfg.consoleName}"'';
    network = ''network="${cfg.network}"'';
    volume = ''volume="${cfg.volumeName}"'';
    ready_url = ''ready_url="http://${hostAddress}:${toString cfg.ports.admin}/v1/status/ready"'';

    # Prints running | stopped | absent. `container list` has no server-side label
    # or name filtering, so everything is filtered here with jq. The status field
    # is an object for running containers; the type check keeps this working if a
    # stopped container reports a bare string instead.
    #
    # Containers, volumes, and networks all carry the resource's name at top-level
    # `.id`, so every existence check in this file matches on that.
    fn_container_state = ''
      container_state() {
        local name="$1" out=""
        out=$(${container} list --all --format json 2>/dev/null \
          | jq -r --arg n "$name" '
              (. // [])[]
              | select(.id == $n)
              | (if (.status | type) == "object" then (.status.state // "unknown") else (.status // "unknown") end)
            ' 2>/dev/null | head -n1) || out=""
        if [ -z "$out" ]; then printf 'absent'; else printf '%s' "$out"; fi
      }
    '';

    # The broker's current IP, without the /24 suffix. Not stable across restarts,
    # which is the whole reason the hosts file is regenerated on every bring-up.
    fn_broker_ip = ''
      broker_ip() {
        ${container} inspect "$1" 2>/dev/null \
          | jq -r '.[0].status.networks[0].ipv4Address // empty' 2>/dev/null \
          | cut -d/ -f1
      }
    '';

    fn_broker_ready = ''
      broker_ready() {
        curl -sf --max-time 5 "$ready_url" >/dev/null 2>&1
      }
    '';

    # Apple Container's API server may not be up yet when this runs at login, so
    # this waits rather than failing. `container system status` exits 0 when the
    # server is running and registered, 1 otherwise.
    fn_wait_for_runtime = ''
      wait_for_runtime() {
        local deadline=$((SECONDS + ${toString cfg.runtimeTimeoutSeconds}))
        if ${container} system status >/dev/null 2>&1; then
          return 0
        fi
        printf 'Waiting for the Apple Container service...\n'
        while ! ${container} system status >/dev/null 2>&1; do
          if [ "$SECONDS" -ge "$deadline" ]; then
            printf '\n' >&2
            printf 'Apple Container is installed but its service is not responding.\n\n' >&2
            printf 'Start it with:\n\n    container system start\n\n' >&2
            printf 'If it is already running, the runtime may be wedged. Restart it with:\n\n' >&2
            printf '    container system stop && container system start\n' >&2
            return 1
          fi
          sleep 1
        done
      }
    '';
  };

  mkScript = name: needs: text: pkgs.writeShellApplication {
    inherit name runtimeInputs;
    text = lib.concatStringsSep "\n" (map (n: snippets.${n}) needs) + "\n" + text;
  };
in
{
  redpanda-up = mkScript "redpanda-up"
    ([
      "state_dir"
      "broker"
      "network"
      "volume"
      "ready_url"
      "fn_container_state"
      "fn_broker_ready"
      "fn_wait_for_runtime"
    ]
    # Console-only helpers. Including them when the console is disabled leaves
    # them unused, which fails the writeShellApplication shellcheck.
    ++ lib.optionals cfg.enableConsole [ "hosts_file" "console" "fn_broker_ip" ]) ''
    wait_for_runtime

    mkdir -p "$state_dir"

    # --- volume -------------------------------------------------------------
    # `container volume create` fails when the name already exists, so creation
    # is conditional. A fresh volume mounts root-owned, which masks the image's
    # data directory and makes the broker die with a permission error, so it is
    # chowned to the uid the Redpanda image runs as. Done once, at creation,
    # because the volume persists.
    if ! ${container} volume list --format json 2>/dev/null \
        | jq -e --arg v "$volume" '(. // [])[] | select(.id == $v)' >/dev/null 2>&1; then
      printf 'Creating volume %s...\n' "$volume"
      ${container} volume create "$volume" >/dev/null
      ${container} run --rm \
        --platform ${cfg.platform} \
        -v "$volume":/data \
        docker.io/library/alpine:latest \
        chown -R ${toString cfg.brokerUid}:${toString cfg.brokerGid} /data >/dev/null
    fi

    # --- network ------------------------------------------------------------
    if ! ${container} network list --format json 2>/dev/null \
        | jq -e --arg n "$network" '(. // [])[] | select(.id == $n)' >/dev/null 2>&1; then
      printf 'Creating network %s...\n' "$network"
      ${container} network create "$network" >/dev/null
    fi

    # --- broker -------------------------------------------------------------
    # Three-way branch: `container run --name X` fails if any container called X
    # exists, even a stopped one, so "absent" and "stopped" need different verbs.
    ${lib.optionalString cfg.enableConsole "broker_was_started=0"}
    case "$(container_state "$broker")" in
      running)
        printf 'Broker %s already running.\n' "$broker"
        ;;
      stopped)
        printf 'Starting existing broker %s...\n' "$broker"
        ${container} start "$broker" >/dev/null
        ${lib.optionalString cfg.enableConsole "broker_was_started=1"}
        ;;
      *)
        printf 'Starting broker %s...\n' "$broker"
        ${container} run -d \
          --name "$broker" \
          --network "$network" \
          --platform ${cfg.platform} \
          -l ${labelPrefix}.managed=true \
          -l ${labelPrefix}.role=broker \
          -l ${labelPrefix}.node-id=${toString cfg.nodeId} \
          -v "$volume":${cfg.dataDir} \
          -c ${toString cfg.cpus} -m ${cfg.memory} \
          -p ${hostAddress}:${toString cfg.ports.kafka}:${toString cp.kafkaExternal} \
          -p ${hostAddress}:${toString cfg.ports.admin}:${toString cp.admin} \
          -p ${hostAddress}:${toString cfg.ports.schemaRegistry}:${toString cp.schemaRegistryExternal} \
          -p ${hostAddress}:${toString cfg.ports.proxy}:${toString cp.proxyExternal} \
          ${cfg.redpandaImage} \
          redpanda start \
            --node-id ${toString cfg.nodeId} \
            --kafka-addr internal://0.0.0.0:${toString cp.kafkaInternal},external://0.0.0.0:${toString cp.kafkaExternal} \
            --advertise-kafka-addr internal://${internalHost}:${toString cp.kafkaInternal},external://${hostAddress}:${toString cfg.ports.kafka} \
            --pandaproxy-addr internal://0.0.0.0:${toString cp.proxyInternal},external://0.0.0.0:${toString cp.proxyExternal} \
            --advertise-pandaproxy-addr internal://${internalHost}:${toString cp.proxyInternal},external://${hostAddress}:${toString cfg.ports.proxy} \
            --schema-registry-addr internal://0.0.0.0:${toString cp.schemaRegistryInternal},external://0.0.0.0:${toString cp.schemaRegistryExternal} \
            --rpc-addr 0.0.0.0:${toString cp.rpc} \
            --advertise-rpc-addr ${internalHost}:${toString cp.rpc} \
            --mode dev-container \
            --smp 1 \
            --default-log-level=info >/dev/null
        ${lib.optionalString cfg.enableConsole "broker_was_started=1"}
        ;;
    esac

    # --- readiness ----------------------------------------------------------
    if ! broker_ready; then
      printf 'Waiting for Redpanda to become ready...\n'
      deadline=$((SECONDS + ${toString cfg.readyTimeoutSeconds}))
      until broker_ready; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          printf '\nRedpanda did not become ready within %ss.\n\n' '${toString cfg.readyTimeoutSeconds}' >&2
          printf 'Last 30 log lines from %s:\n' "$broker" >&2
          ${container} logs -n 30 "$broker" >&2 2>&1 || true
          printf '\nFor more:\n\n' >&2
          printf '    container logs %s\n' "$broker" >&2
          printf '    container logs --boot %s\n' "$broker" >&2
          exit 1
        fi
        sleep 1
      done
    fi

    # --- console ------------------------------------------------------------
    ${lib.optionalString cfg.enableConsole ''
      # Apple Container has no container-to-container name resolution, so the name
      # the broker advertises internally is made resolvable by mounting this file
      # over /etc/hosts in Console's container. The broker's IP changes on every
      # restart, so this is regenerated every time and Console is restarted when it
      # changes -- Console does not recover from a stale entry on its own.
      ip="$(broker_ip "$broker")"
      if [ -z "$ip" ]; then
        printf 'Could not determine the IP address of %s; cannot configure Console.\n' "$broker" >&2
        exit 1
      fi

      hosts_changed=0
      tmp_hosts="$(mktemp)"
      {
        printf '127.0.0.1\tlocalhost\n'
        printf '::1\tlocalhost\n'
        printf '%s\t%s\n' "$ip" "${internalHost}"
      } > "$tmp_hosts"
      if [ -f "$hosts_file" ] && cmp -s "$tmp_hosts" "$hosts_file"; then
        hosts_changed=0
      else
        # `cat >` truncates in place and keeps the inode, which matters because
        # this file is bind-mounted into a running container.
        cat "$tmp_hosts" > "$hosts_file"
        hosts_changed=1
      fi
      rm -f "$tmp_hosts"

      console_state="$(container_state "$console")"
      if [ "$console_state" = running ] && { [ "$hosts_changed" = 1 ] || [ "$broker_was_started" = 1 ]; }; then
        printf 'Broker address changed; restarting console %s...\n' "$console"
        ${container} stop "$console" >/dev/null 2>&1 || true
        ${container} start "$console" >/dev/null
      else
        case "$console_state" in
          running)
            printf 'Console %s already running.\n' "$console"
            ;;
          stopped)
            printf 'Starting existing console %s...\n' "$console"
            ${container} start "$console" >/dev/null
            ;;
          *)
            printf 'Starting console %s...\n' "$console"
            ${container} run -d \
              --name "$console" \
              --network "$network" \
              --platform ${cfg.platform} \
              -l ${labelPrefix}.managed=true \
              -l ${labelPrefix}.role=console \
              -p ${hostAddress}:${toString cfg.ports.console}:${toString cp.console} \
              -e CONFIG_FILEPATH=/etc/console/config.yaml \
              -v "$hosts_file":/etc/hosts \
              -v ${consoleConfig}:/etc/console/config.yaml \
              ${cfg.consoleImage} >/dev/null
            ;;
        esac
      fi
    ''}

    printf '\nRedpanda is ready.\n\n'
    printf '  Kafka            %s:%s\n' '${hostAddress}' '${toString cfg.ports.kafka}'
    printf '  Admin API        %s:%s\n' '${hostAddress}' '${toString cfg.ports.admin}'
    printf '  Schema Registry  %s:%s\n' '${hostAddress}' '${toString cfg.ports.schemaRegistry}'
    printf '  HTTP Proxy       %s:%s\n' '${hostAddress}' '${toString cfg.ports.proxy}'
    ${lib.optionalString cfg.enableConsole ''
      printf '  Console          http://%s:%s\n' '${hostAddress}' '${toString cfg.ports.console}'
    ''}
    printf '\n'
  '';

  # Stops the containers and nothing else. Deliberately does not delete the
  # containers, the volume, or the network, so redpanda-up afterwards restores the
  # same data. Console is stopped first so it does not spend its shutdown window
  # reconnecting to a broker that is going away.
  redpanda-down = mkScript "redpanda-down"
    [ "broker" "console" "fn_container_state" ] ''
    for name in "$console" "$broker"; do
      case "$(container_state "$name")" in
        running)
          printf 'Stopping %s...\n' "$name"
          ${container} stop "$name" >/dev/null 2>&1 || true
          ;;
        stopped)
          printf '%s already stopped.\n' "$name"
          ;;
        *)
          ;;
      esac
    done
    printf 'Redpanda stopped. Data is preserved; run redpanda-up to start again.\n'
  '';

  # Exits non-zero when the broker is not running and serving, so it is usable as
  # a gate in scripts and just recipes.
  redpanda-status = mkScript "redpanda-status"
    ([ "broker" "ready_url" "fn_container_state" "fn_broker_ready" ]
    # The console name is only referenced in the console-enabled block below.
    ++ lib.optionals cfg.enableConsole [ "console" ]) ''
    if ! ${container} system status >/dev/null 2>&1; then
      printf 'The Apple Container service is not running.\n\n' >&2
      printf 'Start it with:\n\n    container system start\n' >&2
      exit 1
    fi

    printf '%-20s %-8s %-9s %s\n' NAME ROLE STATE ADDRESS

    broker_status="$(container_state "$broker")"
    printf '%-20s %-8s %-9s %s\n' "$broker" broker "$broker_status" \
      '${hostAddress}:${toString cfg.ports.kafka}'

    ${lib.optionalString cfg.enableConsole ''
      console_status="$(container_state "$console")"
      printf '%-20s %-8s %-9s %s\n' "$console" console "$console_status" \
        'http://${hostAddress}:${toString cfg.ports.console}'
    ''}

    printf '\n'

    # A container can be `running` while Redpanda is still starting or has wedged,
    # so report what the Admin API says rather than trusting container state.
    if broker_ready; then
      printf 'Broker is ready (%s).\n' "$ready_url"
    else
      printf 'Broker is NOT ready (%s did not respond).\n' "$ready_url" >&2
      exit 1
    fi

    if [ "$broker_status" != running ]; then
      exit 1
    fi
  '';

  # A thin convenience over `container logs`, not a reimplementation of it. With no
  # container name it tails the broker; any other arguments pass straight through.
  redpanda-logs = mkScript "redpanda-logs"
    [ "broker" "console" ] ''
    target="$broker"
    args=()
    for arg in "$@"; do
      case "$arg" in
        "$broker"|"$console")
          target="$arg"
          ;;
        *)
          args+=("$arg")
          ;;
      esac
    done

    if [ ''${#args[@]} -eq 0 ]; then
      exec ${container} logs "$target"
    fi
    exec ${container} logs "''${args[@]}" "$target"
  '';

  # The only destructive command here: it deletes the broker's data volume, and
  # there is no undo. Hence the prompt.
  #
  # The order below is mandatory. A volume cannot be deleted while any container,
  # running or stopped, still references it, so containers must be deleted first.
  # Every step tolerates its resource being absent, which makes the script
  # idempotent and means a purge that failed halfway is finished by running it again.
  redpanda-purge = mkScript "redpanda-purge"
    [ "state_dir" "hosts_file" "broker" "console" "network" "volume" "fn_container_state" ] ''
    force=0
    for arg in "$@"; do
      case "$arg" in
        -f|--force) force=1 ;;
        *)
          printf 'Unknown argument: %s\n' "$arg" >&2
          printf 'Usage: redpanda-purge [--force]\n' >&2
          exit 2
          ;;
      esac
    done

    if [ "$force" -ne 1 ]; then
      printf 'This deletes the Redpanda containers, the network, and the data volume\n'
      printf '%s -- every topic and message in the cluster.\n\n' "$volume"
      printf 'This cannot be undone. Type "yes" to continue: '
      read -r reply
      if [ "$reply" != yes ]; then
        printf 'Aborted; nothing was removed.\n'
        exit 0
      fi
    fi

    for name in "$console" "$broker"; do
      if [ "$(container_state "$name")" != absent ]; then
        # Only ever touch containers this module created. `container list` has no
        # server-side label filter, so the check happens here.
        managed=$(${container} inspect "$name" 2>/dev/null \
          | jq -r '.[0].configuration.labels["${labelPrefix}.managed"] // empty' 2>/dev/null) || managed=""
        if [ "$managed" != true ]; then
          printf 'Refusing to delete %s: it is not labelled %s.managed=true.\n' \
            "$name" '${labelPrefix}' >&2
          continue
        fi
        printf 'Removing container %s...\n' "$name"
        ${container} stop "$name" >/dev/null 2>&1 || true
        ${container} delete "$name" >/dev/null 2>&1 || true
      fi
    done

    if ${container} volume list --format json 2>/dev/null \
        | jq -e --arg v "$volume" '(. // [])[] | select(.id == $v)' >/dev/null 2>&1; then
      printf 'Removing volume %s...\n' "$volume"
      ${container} volume delete "$volume" >/dev/null 2>&1 || true
    fi

    if ${container} network list --format json 2>/dev/null \
        | jq -e --arg n "$network" '(. // [])[] | select(.id == $n)' >/dev/null 2>&1; then
      printf 'Removing network %s...\n' "$network"
      ${container} network delete "$network" >/dev/null 2>&1 || true
    fi

    rm -f "$hosts_file"
    printf 'Purge complete.\n'
  '';
}
