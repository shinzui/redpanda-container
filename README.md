# redpanda-container

A local [Redpanda](https://redpanda.com) cluster running on [Apple
Container](https://github.com/apple/container), packaged as a `home-manager` module.

Redpanda is a streaming data platform that speaks the Kafka protocol, so anything that can
talk to Kafka can talk to it. Apple Container is Apple's macOS container runtime, which runs
each Linux container as a lightweight virtual machine. Together they replace the usual
"start Colima, then run `rpk container start`" arrangement: no second virtual machine, no
Docker daemon, and the whole thing declared in Nix.

One broker and one Redpanda Console run on fixed loopback ports, started at login, with
broker data on a named volume so it survives restarts.

## Requirements

An Apple Silicon Mac running macOS 26 or later. Apple Container's user-defined networks do
not exist on macOS 15, and this module cannot work without them.

## Using it

Add the flake as an input and import the module:

```nix
{
  inputs.redpanda-container.url = "github:shinzui/redpanda-container";

  # in your home-manager configuration:
  imports = [ inputs.redpanda-container.homeManagerModules.default ];
  services.redpanda-container.enable = true;
}
```

That installs five commands and a launchd agent that brings the cluster up at login.

```bash
$ redpanda-up
Creating volume redpanda-0-data...
Creating network redpanda...
Starting broker redpanda-0...
Starting console redpanda-console...

Redpanda is ready.

  Kafka            127.0.0.1:9092
  Admin API        127.0.0.1:9644
  Schema Registry  127.0.0.1:8081
  HTTP Proxy       127.0.0.1:8082
  Console          http://127.0.0.1:8080

$ redpanda-status
NAME                 ROLE     STATE     ADDRESS
redpanda-0           broker   running   127.0.0.1:9092
redpanda-console     console  running   http://127.0.0.1:8080

Broker is ready (http://127.0.0.1:9644/v1/status/ready).
```

Then, from any directory:

```bash
$ rpk topic create orders --brokers 127.0.0.1:9092
$ echo hello | rpk topic produce orders --brokers 127.0.0.1:9092
$ rpk topic consume orders -n 1 --brokers 127.0.0.1:9092
{"topic":"orders","value":"hello","partition":0,"offset":0}
```

## The five commands

`redpanda-up` brings the cluster up. It is idempotent: every resource is created only if
absent, and a container is started only if it exists and is stopped. Running it against an
already-running cluster changes nothing. If the broker does not become ready in time it
prints the broker's recent logs and the commands to see more, rather than a bare timeout.

`redpanda-down` stops the containers and nothing else. Data, the volume, and the network all
survive, so `redpanda-up` afterwards restores the same topics and messages.

`redpanda-status` prints a table of what is running and separately probes the Admin API,
because a container can be `running` while Redpanda is still starting or has wedged. It
exits non-zero when the broker is not serving, so it works as a gate in scripts.

`redpanda-logs` is a thin convenience over `container logs`. With no arguments it tails the
broker; pass `redpanda-console` for Console, and any other flags go straight through.

`redpanda-purge` deletes the containers, the network, and **the data volume** — every topic
and message. It prompts unless given `--force`, is idempotent, and refuses to touch any
container not labelled `dev.shinzui.redpanda.managed=true`.

## Options

All under `services.redpanda-container`. Every value the wrapper scripts use is an option;
nothing is hard-coded in the shell.

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Turn the module on |
| `package` | `pkgs.container` | The Apple Container package |
| `redpandaImage` | `docker.io/redpandadata/redpanda:v26.2.1` | Broker image |
| `consoleImage` | `docker.io/redpandadata/console:v3.9.0` | Console image |
| `platform` | `linux/arm64` | Passed to `container run` |
| `enableConsole` | `true` | Whether to run Console |
| `network` | `redpanda` | User-defined network name |
| `brokerName` | `redpanda-0` | Broker container name |
| `consoleName` | `redpanda-console` | Console container name |
| `volumeName` | `redpanda-0-data` | Named volume holding broker data |
| `labelPrefix` | `dev.shinzui.redpanda` | Label prefix; `redpanda-purge` filters on it |
| `internalHost` | `redpanda-0` | What the broker advertises to Console |
| `hostAddress` | `127.0.0.1` | Address ports are published on |
| `ports.*` | 9092/9644/8081/8082/8080 | Kafka, Admin, Schema Registry, Proxy, Console |
| `cpus` / `memory` | `2` / `2G` | Broker container resources |
| `stateDir` | `~/.local/state/redpanda` | Generated hosts file and agent logs |
| `autoStart` | `true` | Install the launchd agent |
| `readyTimeoutSeconds` | `120` | How long to wait for the broker |
| `runtimeTimeoutSeconds` | `60` | How long to wait for Apple Container itself |

## Two things that look strange and are not

**The broker advertises two different addresses.** A Kafka client connects, asks the broker
for metadata, and then connects to whatever addresses the broker advertised — so the broker
must advertise an address that is correct from the perspective of whoever is asking. Console
runs in a container where `127.0.0.1` means Console itself, so it is told the broker is at
`redpanda-0:9092`. `rpk` runs on macOS, so it is told `127.0.0.1:9092`, which works because
the container's external listener port is published there. Each listener advertises the
address correct for clients arriving on it.

**Console gets a generated `/etc/hosts` bind-mounted into it.** Apple Container has no
container-to-container name resolution at all — not by bare name, not by a DNS domain
registered with `sudo container system dns create`. So `redpanda-up` reads the broker's IP
after starting it, writes a hosts file, and mounts it over `/etc/hosts` in Console's
container. Because the broker's IP changes on every restart, that file is regenerated on
every bring-up and Console is restarted when it changes; Console does not recover from a
stale entry on its own.

Both of these are consequences of behaviour verified by hand first. The transcripts are in
[`docs/spikes/1-apple-container-redpanda-findings.md`](docs/spikes/1-apple-container-redpanda-findings.md).

## Troubleshooting

If Console cannot reach the broker, or containers cannot reach each other at all, the
runtime's networking has probably degraded — this happens, and it is not caused by anything
this module does. Restart it:

```bash
container system stop && container system start
redpanda-up
```

If `redpanda-up` reports the Apple Container service is not responding, start it with
`container system start`.

To reset completely, `redpanda-purge --force` followed by `redpanda-up` gives a clean
cluster. This destroys all data.

## Why there is no `redpanda` CLI here

This repository ships shell wrappers generated from Nix rather than a compiled tool with a
runtime abstraction over Docker, Podman, and Apple Container. That was a deliberate choice
with recorded reversal criteria — see
[`docs/adr/1-no-compiled-cli-for-local-redpanda.md`](docs/adr/1-no-compiled-cli-for-local-redpanda.md).
The naming, labelling, and port contract that anything coexisting with these containers
depends on is in
[`docs/adr/2-redpanda-container-naming-and-port-contract.md`](docs/adr/2-redpanda-container-naming-and-port-contract.md).

The full reasoning for the initiative, including what was excluded and why, is in
[`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`](docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md).

## Development

```bash
nix flake check                                        # evaluate everything
nix build .#redpanda-scripts                           # build the five wrappers
./result/bin/redpanda-up                               # run them without home-manager
nix build .#homeConfigurations.test.activationPackage  # prove the module composes
```

The scripts are built with `writeShellApplication`, which runs `shellcheck` at build time.
A shellcheck warning fails the build; fix the shell rather than suppressing it.
