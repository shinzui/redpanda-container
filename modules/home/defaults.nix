# Default values for every knob the wrapper scripts read.
#
# This file exists so the scripts can be built and exercised standalone with
# `nix build .#redpanda-scripts`, without home-manager supplying an option set.
# The home-manager module declares options with these same defaults and passes
# the resolved values to modules/home/scripts.nix, so the two stay in step.
#
# Everything the scripts depend on lives here rather than being hard-coded in the
# shell. That is deliberate: it keeps a future second instance (a throwaway
# cluster for destructive tests, say) a matter of passing different values rather
# than rewriting the scripts.
{ pkgs }:

{
  # Apple Container. Exposed as an option rather than pinned to pkgs.container
  # because plain nixpkgs ships 1.1.0 while the dotfiles overlay shadows it with
  # a newer build. See MasterPlan Integration Point 1.
  package = pkgs.container;

  # Pulled from Docker Hub rather than docker.redpanda.com: the latter rate-limited
  # every attempt during the spike (persistent HTTP 429). Versions are pinned so a
  # rebuild is reproducible; the broker matches the installed rpk v26.2.1.
  redpandaImage = "docker.io/redpandadata/redpanda:v26.2.1";
  consoleImage = "docker.io/redpandadata/console:v3.9.0";

  # Required. Both images are multi-arch, and Apple Container selected the amd64
  # variant on this arm64 machine during the spike, which would run Redpanda under
  # emulation with no warning.
  platform = "linux/arm64";

  enableConsole = true;

  # The naming contract, fixed in MasterPlan Integration Point 2.
  network = "redpanda";
  brokerName = "redpanda-0";
  consoleName = "redpanda-console";
  volumeName = "redpanda-0-data";
  nodeId = 0;

  # Label prefix. Deliberately unlike `rpk container start`'s own labels
  # (cluster-id, node-id) so a Docker-based cluster and this one are never
  # confused. redpanda-purge filters strictly on this prefix, which is what stops
  # it from ever deleting a container it did not create.
  labelPrefix = "dev.shinzui.redpanda";

  # What the broker advertises to clients arriving on its *internal* listener --
  # in practice, Console. The spike established that Apple Container has no
  # container-to-container name resolution at all, so this name is made resolvable
  # by generating a hosts file from the broker's actual IP and bind-mounting it
  # over /etc/hosts in Console's container. See docs/spikes/1-*.md, Experiment C.
  internalHost = "redpanda-0";

  # Host side. hostAddress appears both in --publish and in the externally
  # advertised address, and those two uses must agree, which is why it is one value.
  hostAddress = "127.0.0.1";
  ports = {
    kafka = 9092;
    admin = 9644;
    schemaRegistry = 8081;
    proxy = 8082;
    console = 8080;
  };

  # Container-side ports. Redpanda binds two listeners for Kafka, the schema
  # registry, and the HTTP proxy: an `internal` one other containers use and an
  # `external` one published to the host. The external container ports are the
  # 1xxxx variants, so host 9092 maps to container 19092.
  containerPorts = {
    kafkaInternal = 9092;
    kafkaExternal = 19092;
    schemaRegistryInternal = 8081;
    schemaRegistryExternal = 18081;
    proxyInternal = 8082;
    proxyExternal = 18082;
    admin = 9644;
    console = 8080;
    rpc = 33145;
  };

  # Redpanda's data directory inside the broker container.
  dataDir = "/var/lib/redpanda/data";

  # The uid:gid the Redpanda image runs as. A freshly created Apple Container
  # volume mounts root-owned and masks the image's correctly-owned data directory,
  # which kills the broker at startup with a permission error. The volume is
  # chowned to this once, at creation. See docs/spikes/1-*.md, Experiment E.
  brokerUid = 101;
  brokerGid = 101;

  cpus = 2;
  memory = "2G";

  # Shell-expandable, not a Nix-resolved path, so the scripts work standalone as
  # well as under home-manager. The module overrides it with an absolute path.
  stateDir = "\${XDG_STATE_HOME:-$HOME/.local/state}/redpanda";

  # The broker reported ready about a second after its container was running
  # during the spike. This ceiling is generous on purpose: it is the difference
  # between a slow login and a failed one.
  readyTimeoutSeconds = 120;

  # How long to wait for Apple Container's own API server. The launchd agent may
  # fire at login before container-apiserver is up, so this is a race that must be
  # waited out rather than failed on.
  runtimeTimeoutSeconds = 60;
}
