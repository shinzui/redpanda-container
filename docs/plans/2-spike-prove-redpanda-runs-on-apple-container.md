---
id: 2
slug: spike-prove-redpanda-runs-on-apple-container
title: "Spike: prove Redpanda runs on Apple Container"
kind: exec-plan
created_at: 2026-08-09T00:15:01Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
master_plan: "docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md"
---


# Spike: prove Redpanda runs on Apple Container

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

This plan proves, by hand and with recorded shell transcripts, that a Redpanda broker and
a Redpanda Console can run on Apple's `container` runtime and be used from macOS. It
writes no permanent code. Its deliverable is a findings document —
`docs/spikes/1-apple-container-redpanda-findings.md` in this repository — and a set of
decisions that plan 3 turns into a `home-manager` module.

A *spike* here means a deliberately throwaway experiment: you type commands, you observe
what happens, you write down what you observed, and then you delete the containers. None
of the commands you run in this plan get committed as scripts.

The reason to do this before writing the module is that three of the behaviours the module
depends on are not reliably documented:

1. Whether a Redpanda Console container can reach a Redpanda broker container by name over
   an Apple Container user-defined network, and what exact name string works.
2. Whether data written to a named Apple Container volume survives deleting and recreating
   the container that used it.
3. Whether Redpanda's listener model — which advertises one address to other containers
   and a different address to clients on the Mac — behaves on Apple Container's networking
   the way it does on Docker's.

Getting any of these wrong while building the module means debugging through launchd logs,
which is slow and unpleasant. Getting them right first means the module is mostly
transcription.

After this plan you will have personally seen this work:

```bash
$ echo "hello" | rpk topic produce spike-test --brokers 127.0.0.1:9092
$ rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
{"topic":"spike-test","value":"hello","timestamp":...,"partition":0,"offset":0}
```

and this, in a browser at `http://127.0.0.1:8080`: Redpanda Console listing the broker and
the `spike-test` topic — proving Console reached the broker over the container network.

This is child plan 2 of the MasterPlan at
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`.


## Progress

All experiments complete, 2026-08-08. Two experiments were added that the plan did not
anticipate (B2 and H2); both are recorded in the findings document.

- [x] Confirm the prerequisites from plan 1 hold (`container` installed, service running, networks available) (2026-08-08)
- [x] Experiment A: pull the Redpanda and Console images (2026-08-08) — required a registry change and an explicit `--platform`
- [x] Experiment B: create a user-defined network and prove two containers can reach each other (2026-08-08)
- [x] Experiment B2 (added): establish that container-to-container networking degrades and that a runtime restart repairs it (2026-08-08)
- [x] Experiment C: determine the exact working name string for container-to-container addressing (2026-08-08) — **no name string resolves**; a bind-mounted `/etc/hosts` is the answer
- [x] Experiment D: create a named volume, write to it, delete the container, recreate, verify data survived (2026-08-08)
- [x] Experiment E: start a single Redpanda broker in `dev-container` mode with a named volume (2026-08-08) — required chowning the volume to `101:101`
- [x] Experiment F: produce and consume from macOS through the published Kafka port (2026-08-08)
- [x] Experiment G: verify Admin API, Schema Registry, and HTTP Proxy from macOS (2026-08-08)
- [x] Experiment H: start Console and verify it sees the broker and topics (2026-08-08)
- [x] Experiment H2 (added): establish that Console breaks when the broker's IP changes, and verify the remediation (2026-08-08)
- [x] Experiment I: verify data persistence across a full stop/start *and* full delete/recreate of the broker container (2026-08-08)
- [x] Experiment J: verify labels and JSON output are usable for status and cleanup (2026-08-08)
- [x] Write `docs/spikes/1-apple-container-redpanda-findings.md` (2026-08-08)
- [x] Record the internal-addressing decision in the Decision Log (2026-08-08)
- [x] Tear down every resource created by the spike and verify nothing is left behind (2026-08-08)
- [ ] Optional cleanup left to the user: `sudo container system dns delete test` removes the DNS domain created during Experiment C, which proved useless and is not needed by any later plan


## Surprises & Discoveries

Full transcripts for all of these are in
`docs/spikes/1-apple-container-redpanda-findings.md`; this section records what was
surprising and why it mattered.

**Container-to-container name resolution does not work at all.** The plan expected one of
three name forms to work and framed the experiment as "determine which". The answer is
none. Bare names fail, `--dns-domain` alone fails, and a domain registered with
`sudo container system dns create test` fails too — the embedded resolver answers NXDOMAIN.
Retested after restarting the runtime and recreating both containers so neither predated
the domain. Containers on the *default* network cannot resolve each other either, so it is
not a user-defined-network limitation. Reading `/etc/resolver/containerization.test`
explains why: `container system dns create` writes a **macOS-side** resolver pointing at a
host DNS service on `127.0.0.1:2053`; it is for resolving containers *from macOS*, not for
container-to-container resolution.

This invalidated the plan's assumption that its three candidates were exhaustive. The
solution actually used — bind-mounting a hosts file over `/etc/hosts` — was not among them.

**The `sudo` question the plan asked has an inverted answer.** The plan asked whether a
`sudo container system dns create` step must go in plan 4's runbook. It must not: it was
tested and does not help. Answering "no" here is more valuable than answering "yes" would
have been, because it removes a privileged step from the setup instructions.

**Networking degraded mid-spike and a runtime restart repaired it.** Connectivity that had
been demonstrated working stopped working entirely — 100% packet loss between containers,
including freshly created ones. The initial hypothesis was that publishing ports caused it,
since the broker published four and the working pair published none. That was tested
directly and disproved: with networking degraded, a container with a published port and one
without were equally unreachable. `container system stop && container system start` restored
it completely. The MasterPlan had recorded community reports of this after host sleep/wake;
it happened here with no sleep involved, so plan 3 should treat it as ordinary rather than
exotic.

**The Redpanda image cannot use a fresh named volume without a chown.** The broker died on
startup with `mkdir failed: Permission denied ["/var/lib/redpanda/data/crash_reports"]`. The
image runs as `uid=101(redpanda)` and ships that directory owned by 101, but an Apple
Container named volume mounts root-owned and masks it. A single
`chown -R 101:101` on the volume fixes it permanently. This is exactly the class of problem
the plan predicted would be miserable to debug through launchd logs later.

**Apple Container pulled the wrong architecture by default.** For the multi-arch
`redpandadata/redpanda:v26.2.1`, it selected `linux/amd64` on this arm64 machine. Nothing
warns about this; the container would simply have run under emulation. `--platform
linux/arm64` on both `pull` and `run` fixes it.

**`docker.redpanda.com` rate-limited every attempt.** Persistent HTTP 429 across several
minutes and multiple retries. Docker Hub carries the same images and worked. A related trap:
piping `container image pull` into `tail` masks its exit status, which briefly made a failed
pull look successful — the command genuinely does exit 1 on failure.

**Container IPs are not stable, and Console does not tolerate that.** A single broker
container held `.5`, `.4`, then `.8` across the spike. Because the hosts-file workaround
freezes the IP at Console start time, recreating the broker left Console dialling a dead
address and returning HTTP 500 from `/api/topics`. Regenerating the hosts file and
restarting Console fixed it. This makes "restart the broker" an unsupported standalone
operation for plan 3.

**`container network list` has no `STATE` column**, contrary to plan 1's prediction. Actual
columns are `NETWORK  SUBNET`.

**`container list` has no server-side label filtering**, so status and purge scripts must
list everything and filter `.configuration.labels` with `jq`.


## Decision Log

- Decision: Run the spike by hand rather than as a committed script.
  Rationale: the point is to observe behaviour and make a decision, not to produce a
  reusable artifact. A committed script invites being mistaken for the real
  implementation, which section 36 of `docs/initial-spec.md` explicitly warns against
  ("Do not merge the spike as the final implementation"). The findings document is the
  durable output.
  Date: 2026-08-08

- Decision: Test container-to-container addressing in a fixed order — bare container name,
  then name qualified by the DNS domain, then IP address from `container inspect` — and
  use the first that works.
  Rationale: the bare name produces the simplest module and matches the Redpanda
  quickstart `docker-compose.yml`. The qualified name is what Apple's own tutorial
  demonstrates. The IP is the most reliable but requires the module to run `container
  inspect` and re-render arguments at start time, which is materially more complex, so it
  is the last resort.
  Date: 2026-08-08

- Decision: **The internal addressing decision (MasterPlan Integration Point 3).** The broker
  advertises the fixed container name `redpanda-0`; Console resolves that name through a
  hosts file generated on macOS at start time from the broker's discovered IP and
  bind-mounted over `/etc/hosts` in Console's container.
  Rationale: all three candidates the plan enumerated were tested and all three failed. Bare
  and domain-qualified names do not resolve even with a registered DNS domain, and a raw IP
  cannot be used because the broker's advertised address is fixed at `container run` time —
  before the container has an IP — and because IPs change on every restart. Mounting a hosts
  file keeps a *stable name* in the advertised address, which is what Kafka's metadata
  exchange needs, while letting the actual address be resolved late. It was chosen over the
  alternative of running Console's entrypoint as root and appending to `/etc/hosts` in-process
  because the mount works for the image's normal non-root user (`uid=100`), needs no
  entrypoint override, and keeps the config file mountable by the same mechanism.
  Date: 2026-08-08

- Decision: Pull images from `docker.io/redpandadata/...` rather than
  `docker.redpanda.com/redpandadata/...`, and always pass `--platform linux/arm64`.
  Rationale: the documented registry rate-limited every attempt with HTTP 429 over several
  minutes. Docker Hub serves the same images. The explicit platform is required because
  Apple Container selected the `linux/amd64` variant of the multi-arch image on this arm64
  machine, which would have run Redpanda under emulation silently.
  Date: 2026-08-08

- Decision: Chown the data volume to `101:101` as part of creating it, rather than running
  the broker as root or using a bind mount from macOS.
  Rationale: the image runs as `uid=101(redpanda)` and a fresh Apple Container named volume
  mounts root-owned, which masks the image's correctly-owned data directory and kills the
  broker at startup. A one-time chown is the smallest change, preserves the image's own
  security posture, and persists because the volume persists.
  Date: 2026-08-08

- Decision: Treat "restart the broker" as an unsupported standalone operation; anything that
  restarts the broker must also regenerate the hosts file and restart Console.
  Rationale: the broker's IP changes on every restart, and Console's mounted hosts file
  freezes the IP at Console start time. This was observed and the remediation verified.
  Plan 3's `redpanda-up` must therefore order its work: start broker, wait for ready, read
  IP, write hosts file, start Console.
  Date: 2026-08-08


## Outcomes & Retrospective

**What was achieved.** Redpanda and Redpanda Console both run on Apple Container, and the
MasterPlan's design is achievable. The behavioural acceptance was observed directly, with
Colima not running:

```text
$ echo "hello" | rpk topic produce spike-test --brokers 127.0.0.1:9092
Produced to partition 0 at offset 0 with timestamp 1786242553203.
$ rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
{"topic":"spike-test","value":"hello","timestamp":1786242553203,"partition":0,"offset":0}
```

and Console served HTTP 200 on `127.0.0.1:8080` while listing `spike-test`, proving it
reached the broker over the container network on the `internal` listener at the same time
`rpk` was using the `external` one. Data survived both a stop/start and a full
delete-and-recreate of the broker container against the same named volume. The findings
document `docs/spikes/1-apple-container-redpanda-findings.md` contains real transcripts for
all twelve experiments and answers every acceptance question the plan posed. All spike
resources were torn down and verified gone.

**What changed relative to the plan.** The plan framed Experiment C as choosing among three
name forms. All three failed, so the deliverable became a mechanism the plan had not
considered: a bind-mounted `/etc/hosts` file. Two experiments were added — B2 (networking
degradation) and H2 (Console breaking on IP change) — because both were discovered while
diagnosing failures and both constrain plan 3's design. Four findings that the plan did not
anticipate at all (registry rate limiting, wrong default architecture, volume ownership,
networking fragility) would each individually have cost a debugging cycle inside a launchd
agent, which is precisely the outcome this spike existed to prevent.

**Lessons worth carrying forward.** The plan's instruction to isolate variables paid for
itself twice. Using plain Alpine containers for the networking and volume experiments meant
that when the broker later failed, "Redpanda is misconfigured" could be separated from
"networking is broken" immediately. And when Console could not reach the broker, testing a
published-port container against a non-published one disproved the obvious hypothesis in one
command — without that, the port-publishing theory would have been plausible enough to build
a workaround around, and the workaround would not have helped.

The second lesson is that reading the artifact a tool generates beats trusting its
documentation. Apple's tutorial implies `container system dns create` enables container name
resolution; `cat /etc/resolver/containerization.test` shows in four lines that it configures
macOS-side resolution instead. That file explained a failure that three rounds of retrying
had not.

**Bearing on later plans.** Plan 3 must render: the `docker.io` registry with
`--platform linux/arm64`; a volume chowned to `101:101`; `--advertise-kafka-addr
internal://redpanda-0:9092,external://127.0.0.1:9092`; a generated hosts file mounted into
Console; a readiness poll on `http://127.0.0.1:9644/v1/status/ready`; and a strict start
order of broker → ready → read IP → write hosts → Console. It must not assume the broker can
be restarted independently of Console, and it should verify container-to-container
connectivity rather than assume it. Plan 4 must **not** include a
`sudo container system dns create` step in the runbook, and should document
`container system stop && container system start` as the remedy when Console cannot reach the
broker.


## Context and Orientation

### What you need before starting

This plan depends on plan 1
(`docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md`) being complete.
Specifically you need `container` on `PATH`, its background service running, and
user-defined networks available. Verify all three before doing anything else:

```bash
container --version           # expect 1.2.2 or newer
container system status       # expect a running API server
container network list        # expect at least a "default" network, not an error
```

If `container network list` errors, you are on macOS 15 or earlier and this plan cannot
proceed — Apple Container has no user-defined networks there and containers cannot reach
each other at all.

You also need `rpk`, the Redpanda command-line tool, which is already installed on this
machine from Homebrew:

```bash
$ rpk version
rpk version: v26.2.1
```

### What Redpanda is, in the terms this plan uses

Redpanda is a streaming data platform that speaks the Kafka protocol. For this plan you
need to know that a single Redpanda process exposes five network services:

- **Kafka API** on port 9092 by default — what producers and consumers talk to.
- **Admin API** on port 9644 — health, configuration, cluster status. Plain HTTP.
- **Schema Registry** on port 8081 — stores message schemas. Plain HTTP.
- **HTTP Proxy** (also called "pandaproxy") on port 8082 — produce and consume over HTTP.
- **RPC** on port 33145 — how brokers talk to each other. With one broker, nothing external
  needs this.

**Redpanda Console** is a separate program, shipped as its own container image, that
provides a web UI. It connects to the broker's Kafka API, Schema Registry, and Admin API
as an ordinary client. Because it runs in its own container, it must reach the broker over
the container network, not over `127.0.0.1`.

### The listener model, explained

This is the part that makes container networking non-trivial, so it is worth stating
carefully.

A Kafka client does not just connect to a broker once. It connects, asks for metadata, and
the broker replies with the addresses at which its brokers can be reached. The client then
connects to *those* addresses. This means a broker must advertise an address that is
correct *from the perspective of the client asking*.

Two kinds of client exist here, and they need different answers:

- **Console**, running in a container on the container network. From there, `127.0.0.1`
  means Console itself. It needs the broker's address on the container network — something
  like `redpanda-0:9092`.
- **`rpk` and application code**, running on macOS. From there, the container network's
  addresses are not directly routable in a way you want to depend on. What works is a
  *published port*: `container run -p 127.0.0.1:9092:9092` makes macOS's
  `127.0.0.1:9092` forward into the container. So macOS clients need the broker to
  advertise `127.0.0.1:9092`.

Redpanda solves this with named listeners. It can bind two Kafka listeners at once and
advertise a different address for each:

```text
--kafka-addr           internal://0.0.0.0:9092,external://0.0.0.0:19092
--advertise-kafka-addr internal://redpanda-0:9092,external://127.0.0.1:9092
```

Read that as: bind a listener named `internal` on all interfaces port 9092, and a listener
named `external` on all interfaces port 19092. Tell clients that arrive on `internal` that
brokers live at `redpanda-0:9092`; tell clients that arrive on `external` that brokers live
at `127.0.0.1:9092`. Then publish container port 19092 to host port 9092, so a macOS client
connecting to `127.0.0.1:9092` lands on the `external` listener and is told to keep using
`127.0.0.1:9092`. Console connects to `redpanda-0:9092`, lands on `internal`, and is told
to keep using `redpanda-0:9092`. Both are self-consistent.

The invariant to hold onto: **never advertise `localhost` to another container, and never
advertise a container-network address to a macOS client.**

For reference, the Redpanda quickstart `docker-compose.yml` from the official
documentation uses exactly this shape for its first broker:

```text
redpanda start
  --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092
  --advertise-kafka-addr internal://redpanda-0:9092,external://localhost:19092
  --pandaproxy-addr internal://0.0.0.0:8082,external://0.0.0.0:18082
  --advertise-pandaproxy-addr internal://redpanda-0:8082,external://localhost:18082
  --schema-registry-addr internal://0.0.0.0:8081,external://0.0.0.0:18081
  --rpc-addr redpanda-0:33145
  --advertise-rpc-addr redpanda-0:33145
  --mode dev-container
  --smp 1
  --default-log-level=info
```

Note it uses the container *hostname* `redpanda-0` for internal addresses. That is the
approach this spike tests first.

For contrast, `rpk container start` — the thing being replaced — does something different.
Reading `src/go/rpk/pkg/cli/container/containerutil/common.go` in the
`redpanda-data/redpanda` repository shows it resolves each container's IP address in
advance via Docker's IP address management, and passes that IP into the listener flags:

```go
ip, err := nodeIP(ctx, c, netID, nodeID)
...
cmd := []string{
    "redpanda", "start",
    "--node-id", fmt.Sprintf("%d", nodeID),
    "--kafka-addr", ListenAddresses(ip, config.DefaultKafkaPort, externalKafkaPort),
    "--advertise-kafka-addr", AdvertiseAddresses(ip, config.DefaultKafkaPort, kafkaPort),
    ...
    "--mode dev-container",
}
```

where `AdvertiseAddresses(ip, internal, external)` yields
`internal://<ip>:<internal>,external://127.0.0.1:<external>`. Apple Container's
`container run` has no flag to assign a container's IP in advance, so this approach is not
directly available — hence the spike.

Two further details from that same source are worth knowing because they contradict
reasonable assumptions:

- **`rpk container start` mounts no volume at all.** There is no `Binds` and no `Mounts` in
  its container configuration. Data survives `rpk container stop` / `start` only because
  the container is never deleted. This spike tests a named volume instead, which is a
  different and better arrangement but also an untested one.
- **`--mode dev-container`** is a Redpanda flag that turns on development-appropriate
  settings: overprovisioning (so it does not assume dedicated CPUs), zero reserved memory,
  disabled system checks, and relaxed fsync. It is what makes Redpanda willing to start on
  a laptop with one core allocated.

### What Apple Container gives you

The commands this spike uses, with their exact flags as documented in Apple's command
reference:

- `container image pull <image>` — explicitly pull an image.
- `container network create <name>` — create a user-defined network. macOS 26 and later
  only. Options include `--subnet`, `--label`.
- `container network list --format json` — list networks as JSON.
- `container volume create <name>` — create a named volume. Options include `--label`,
  `-s <size>`, and `--opt journal=<mode>`.
- `container volume list --format json`, `container volume inspect <name>`.
- `container run [options] <image> [args...]` with, relevant here:
  `-d/--detach`, `--name <name>`, `--network <name>`, `-p/--publish [host-ip:]host-port:container-port[/protocol]`,
  `-v/--volume <volume>:<path>`, `-l/--label key=value`, `-e/--env key=value`,
  `-c/--cpus <n>`, `-m/--memory <size>`, `--dns-domain <domain>`, `--entrypoint <cmd>`,
  `--rm`.
- `container list --all --format json` — list containers as JSON.
- `container inspect <name>` — detailed JSON for a container, including its IP.
- `container logs [--follow] [-n <lines>] [--boot] <name>` — container logs. `--boot` shows
  the VM boot log rather than the application's stdio, which is useful when a container
  dies before the application prints anything.
- `container exec <name> <cmd> ...` — run a command inside a running container.
- `container stop <name>`, `container delete <name>` (alias `rm`).

Two behaviours to keep in mind. First, published ports forward to the IP of the interface
attached to the container's **first** network, so if a container is attached to multiple
networks the order matters; this spike attaches each container to exactly one network to
avoid the question. Second, unlike Docker, anonymous volumes are **not** removed by `--rm`;
this spike uses only named volumes, and cleans them up explicitly.

### Apple Container's DNS, and why experiment C exists

Apple Container runs an embedded DNS service. Apple's own tutorial shows a container
resolving another container by name after creating a local domain:

```bash
sudo container system dns create test
container run -it --rm web-test curl http://my-web-server.test
```

The `sudo container system dns create <domain>` step writes a file under `/etc/resolver`
so that **macOS** can resolve `<name>.<domain>`; it requires administrator privileges.
Whether *containers* can resolve each other without that step, and whether a bare name
(`redpanda-0`) works as well as a qualified one (`redpanda-0.test`), is what experiment C
determines. There are also community reports of DNS resolution failing after the host
sleeps and wakes, recovering only after `container system stop && container system start`
— worth watching for and recording if you see it, because plan 3 needs to tolerate it.

`container run` accepts `--dns-domain <domain>` to set a container's default DNS domain,
and `container system property list` reports the system's configured default domain. Both
are inputs to experiment C.

### Images and versions

Use versions matching the installed `rpk` (v26.2.1) rather than `latest`, so the spike's
findings are about a known version:

```text
broker:  docker.redpanda.com/redpandadata/redpanda:v26.2.1
console: docker.redpanda.com/redpandadata/console:v3.9.0
```

Console v3.9.0 is what the current Redpanda quickstart uses and what `rpk` v26.2.1 defaults
to for `rpk container start` (`--console-image` defaults to `redpandadata/console:v3.8.0`
in this `rpk` build; the quickstart's v3.9.0 is newer and is the one to test). Console is
configured through a YAML file whose path is given by the `CONFIG_FILEPATH` environment
variable; the quickstart writes the config inline. `rpk container start` does the same
thing via an entrypoint override:

```go
Entrypoint: []string{"/bin/sh", "-c", fmt.Sprintf("echo \"%v\" > /tmp/redpanda-console-config.yaml; /app/console", cfgStr)},
Env:        []string{"CONFIG_FILEPATH=/tmp/redpanda-console-config.yaml"},
```

That technique — write the config with a shell one-liner in the entrypoint, then exec the
real binary — is what this spike uses, because it avoids needing a bind mount from macOS.

### Naming used by this spike

To keep the spike's resources distinguishable from anything plan 3 later creates, and from
any leftovers of `rpk container start`, prefix everything with `spike-`:

```text
network:           spike-redpanda
broker container:  spike-redpanda-0
console container: spike-redpanda-console
volume:            spike-redpanda-0-data
label:             dev.shinzui.spike=redpanda
```

The final naming contract that plan 3 uses is different (`redpanda`, `redpanda-0`,
`redpanda-console`, `redpanda-0-data`) and is fixed in the MasterPlan's Integration Points
section. Do not use those names here — a leftover spike container called `redpanda-0`
would collide with the real one later.

### Host ports used by this spike

The spike publishes to the same host ports the final design will use, because part of what
is being verified is that those ports are free and that publishing works:

```text
9092  Kafka (external listener)
9644  Admin API
8081  Schema Registry (external listener)
8082  HTTP Proxy (external listener)
8080  Console
```

Before starting, confirm nothing is already listening on them:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9092|9644|8081|8082|8080)\b'
```

Expect no output. If there is output, something else on this machine holds the port — most
likely a Redpanda left over from the Colima setup. Stop it (`rpk container stop`, or
`colima stop`) before continuing, and record the collision in Surprises & Discoveries.

### ADR context

Neither this repository nor `/Users/shinzui/Keikaku/dotfiles.nix` has a `docs/adr/`
directory, and neither has a `mori.dhall`, so neither has a profile-governed ADR bundle.
A Mori registry search found no cross-repository decisions about container runtimes or
Redpanda:

```bash
$ mori registry search redpanda
No projects matching 'redpanda'
$ mori registry concepts --search 'container runtime' --json
[]
```

**No relevant ADR exists.** This plan produces findings rather than architecture; the ADR
candidates for this initiative are owned by plans 3 and 4.


## Plan of Work

Ten experiments, each answering one question, ordered so that a failure stops you before
you waste effort on something that depends on it. Run them in order. After each, paste the
actual output into `docs/spikes/1-apple-container-redpanda-findings.md` — not a summary,
the actual output, because the value of this plan is evidence.

Create the findings file first so you have somewhere to write as you go:

```bash
cd /Users/shinzui/Keikaku/bokuno/redpanda-container
mkdir -p docs/spikes
$EDITOR docs/spikes/1-apple-container-redpanda-findings.md
```

Give it a heading per experiment (A through J), and under each, the command, the output,
and a one-line verdict.

### Experiment A — Images pull

Question: can Apple Container pull the Redpanda images from `docker.redpanda.com`?

This is first because everything else needs the images, and because a registry
authentication or architecture problem here would be a hard blocker. Redpanda publishes
`linux/arm64` images, so no Rosetta emulation should be needed; confirm the architecture
that actually gets pulled.

### Experiment B — Two containers on a user-defined network can reach each other

Question: does container-to-container networking work at all?

Use two trivial Alpine containers rather than Redpanda, so that a failure is unambiguous.
This isolates "networking is broken" from "Redpanda is misconfigured", which are very
different problems and easy to confuse if you skip straight to Redpanda.

### Experiment C — Which name string resolves

Question: what exact string does one container use to address another?

Test, in this order: the bare container name (`spike-a`), the name qualified with the
system's default DNS domain (find it with `container system property list`), and the
container's IP address from `container inspect`. Record which ones resolve and which do
not. This is the decision that plan 3 consumes, so be precise: record the exact string,
not "names work".

If none of the name forms resolve but IP does, that is a valid outcome — record it, and
note that plan 3's module will need to inspect the container after starting it and render
listener arguments from the discovered IP. That is more complex but tractable, and it is
better to know now.

### Experiment D — Named volumes persist across container deletion

Question: if a container writes to a named volume and the container is then deleted, does a
new container mounting the same volume see the data?

This matters because `redpanda-down` followed by `redpanda-up` must not lose topics, and
because the arrangement being tested (named volume) is *not* what `rpk container start`
used, so there is no prior evidence it works for this workload.

Use a trivial container writing a file, not Redpanda — again, to isolate the variable.

### Experiment E — A Redpanda broker starts

Question: does Redpanda actually boot in `dev-container` mode on this runtime, with a named
volume mounted at its data directory, and stay up?

Redpanda's data directory inside the container is `/var/lib/redpanda/data`.

Watch for it dying shortly after start — that is the common failure mode, usually memory or
CPU related. `container logs --boot spike-redpanda-0` shows the VM boot log if the
container dies before Redpanda prints anything, which is the difference between a useful
diagnosis and a shrug.

### Experiment F — Kafka works from macOS

Question: can `rpk` on macOS produce to and consume from the broker through the published
port?

This is the single most important acceptance in the whole MasterPlan. Use explicit
`--brokers 127.0.0.1:9092` rather than relying on an `rpk` profile, because profile setup
is plan 4's job and you do not want a stale profile confusing the result — recall that
`~/Library/Application Support/rpk/rpk.yaml` already contains a profile named
`rpk-container` pointing at these same ports from the old Colima setup.

### Experiment G — Admin API, Schema Registry, and HTTP Proxy work from macOS

Question: do the other three published services respond?

These are lower-stakes than Kafka but are part of what "a working local Redpanda" means,
and a failure here usually indicates a listener bound to the wrong address.

### Experiment H — Console reaches the broker

Question: can Console, in its own container, connect to the broker over the container
network using the internal advertised address, and serve a UI on the published port?

This is the experiment that consumes experiment C's answer. It is also the one that proves
the internal/external listener split is correct: Console using the internal address while
`rpk` uses the external one, simultaneously.

### Experiment I — Data survives a stop/start cycle

Question: after `container stop` and `container start` of the broker, is the topic created
in experiment F still there with its messages?

Then do the stronger version: `container stop`, `container delete`, and `container run`
again with the same volume. That second form is what proves the volume rather than the
container's writable layer is holding the data.

### Experiment J — Labels and JSON output are usable

Question: can the eventual `redpanda-status` and `redpanda-purge` scripts find their
resources reliably?

Verify that labels set with `-l` come back in `container inspect` output, and check whether
`container list` can filter by label or whether the scripts will need to filter the JSON
themselves with `jq`. Look at the JSON shape for the fields a status script needs: name,
state, IP, image. Record the actual JSON structure in the findings — plan 3 will be writing
`jq` expressions against it and guessing the shape is a waste of a debugging cycle.

### Finally — write up and tear down

Consolidate the findings into a short conclusions section at the top of the findings file:
the internal addressing decision, any workarounds required, and anything plan 3 must handle
that was not anticipated. Then delete every resource the spike created and verify nothing
remains.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/redpanda-container` unless noted. Set
these once per shell so the commands below are copy-pasteable:

```bash
RP_IMAGE=docker.redpanda.com/redpandadata/redpanda:v26.2.1
CONSOLE_IMAGE=docker.redpanda.com/redpandadata/console:v3.9.0
NET=spike-redpanda
BROKER=spike-redpanda-0
CONSOLE=spike-redpanda-console
VOL=spike-redpanda-0-data
```

### Step 0 — prerequisites

```bash
container --version
container system status
container network list
rpk version
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9092|9644|8081|8082|8080)\b'
```

The `lsof` command should print nothing.

### Step A — pull images

```bash
container image pull "$RP_IMAGE"
container image pull "$CONSOLE_IMAGE"
container image list
```

Expect both images listed. Record the architecture shown; it should be `arm64`.

### Step B — network and basic connectivity

```bash
container network create "$NET"
container network list

container run -d --name spike-a --network "$NET" \
  docker.io/library/alpine:latest sleep 3600
container run -d --name spike-b --network "$NET" \
  docker.io/library/alpine:latest sleep 3600

container list --all
```

Get `spike-a`'s IP and prove `spike-b` can reach it by IP first — that isolates routing
from name resolution:

```bash
container inspect spike-a
# find the IPv4 address in the JSON, then:
container exec spike-b ping -c 2 <spike-a-ip>
```

If ping by IP fails, container-to-container networking is not working; stop and record it.
Check `container network inspect "$NET"` and whether both containers really landed on that
network.

### Step C — name resolution

```bash
container system property list --format json
```

Find the default DNS domain. Then try each form from inside `spike-b`:

```bash
container exec spike-b getent hosts spike-a
container exec spike-b getent hosts spike-a.<default-domain>
container exec spike-b ping -c 2 spike-a
```

`getent hosts <name>` prints the resolved address and exits 0 on success, exits non-zero
silently on failure — it is a cleaner probe than `ping`, which conflates resolution failure
with unreachability.

If the bare name does not resolve, try creating the domain and using `--dns-domain`:

```bash
sudo container system dns create test
container system dns list
container stop spike-b && container delete spike-b
container run -d --name spike-b --network "$NET" --dns-domain test \
  docker.io/library/alpine:latest sleep 3600
container exec spike-b getent hosts spike-a.test
container exec spike-b getent hosts spike-a
```

Record exactly which strings resolved. **This is the finding plan 3 depends on most.**

Clean up before moving on:

```bash
container stop spike-a spike-b
container delete spike-a spike-b
```

### Step D — volume persistence

```bash
container volume create "$VOL"
container volume list

container run --rm -v "$VOL":/data docker.io/library/alpine:latest \
  sh -c 'echo "written-by-first-container" > /data/marker.txt; cat /data/marker.txt'

container run --rm -v "$VOL":/data docker.io/library/alpine:latest \
  cat /data/marker.txt
```

Expected: the second command prints `written-by-first-container`. The first container was
removed by `--rm` between the two, so this proves the volume, not the container, held it.

```bash
container volume inspect "$VOL"
```

Record the JSON shape, including where the volume lives on the host.

### Step E — start a Redpanda broker

Substitute `<INTERNAL_HOST>` with whatever experiment C proved works — most likely
`spike-redpanda-0`, possibly `spike-redpanda-0.test`.

```bash
container run -d \
  --name "$BROKER" \
  --network "$NET" \
  -l dev.shinzui.spike=redpanda \
  -l dev.shinzui.spike.role=broker \
  -v "$VOL":/var/lib/redpanda/data \
  -c 2 -m 2G \
  -p 127.0.0.1:9092:19092 \
  -p 127.0.0.1:9644:9644 \
  -p 127.0.0.1:8081:18081 \
  -p 127.0.0.1:8082:18082 \
  "$RP_IMAGE" \
  redpanda start \
    --node-id 0 \
    --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092 \
    --advertise-kafka-addr internal://<INTERNAL_HOST>:9092,external://127.0.0.1:9092 \
    --pandaproxy-addr internal://0.0.0.0:8082,external://0.0.0.0:18082 \
    --advertise-pandaproxy-addr internal://<INTERNAL_HOST>:8082,external://127.0.0.1:8082 \
    --schema-registry-addr internal://0.0.0.0:8081,external://0.0.0.0:18081 \
    --rpc-addr 0.0.0.0:33145 \
    --advertise-rpc-addr <INTERNAL_HOST>:33145 \
    --mode dev-container \
    --smp 1 \
    --default-log-level=info
```

Read the port mappings carefully: host 9092 maps to container **19092**, the external
listener, not container 9092 which is the internal one. Same pattern for 8081 and 8082.
The Admin API has no internal/external split, so host 9644 maps to container 9644.

Note also that `--rpc-addr` binds to `0.0.0.0` here rather than to a specific IP as the
quickstart does. That is deliberate: Apple Container does not let you know the container's
IP before it starts, so binding to all interfaces and advertising the name is the workable
combination. If Redpanda rejects this, record it and try binding `--rpc-addr` to the name
instead.

Watch it come up:

```bash
container list --all
container logs -n 50 "$BROKER"
```

If the container is not running, get the boot log:

```bash
container logs --boot "$BROKER"
```

Wait for readiness by polling the Admin API from macOS:

```bash
until curl -sf http://127.0.0.1:9644/v1/status/ready >/dev/null 2>&1; do
  echo "waiting for redpanda..."
  sleep 2
done
echo "ready"
```

If `/v1/status/ready` turns out not to exist on this Redpanda version, find a working
readiness endpoint — `curl -sf http://127.0.0.1:9644/v1/cluster/health_overview` and
`rpk cluster health --exit-when-healthy --brokers 127.0.0.1:9092` are both candidates —
and **record which one you used**, because plan 3's readiness poll needs exactly this.

### Step F — produce and consume from macOS

```bash
rpk cluster info --brokers 127.0.0.1:9092
rpk topic create spike-test --brokers 127.0.0.1:9092
echo "hello" | rpk topic produce spike-test --brokers 127.0.0.1:9092
rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
```

Expected: `rpk cluster info` lists one broker; the consume prints a JSON record whose
`value` is `hello`.

If `rpk cluster info` connects but then hangs or reports an unreachable broker, the
advertised external address is wrong — that is the classic symptom. Check with:

```bash
rpk cluster metadata --brokers 127.0.0.1:9092
```

and confirm the advertised address it reports is `127.0.0.1:9092` and not something else.

### Step G — the other services

```bash
curl -s http://127.0.0.1:9644/v1/status/ready
curl -s http://127.0.0.1:9644/v1/brokers | head -c 400
curl -s http://127.0.0.1:8081/subjects
curl -s http://127.0.0.1:8082/topics
```

Expected: the Admin API returns JSON; `/subjects` returns `[]` (an empty schema registry);
`/topics` lists `spike-test` among any internal topics.

### Step H — Console

```bash
container run -d \
  --name "$CONSOLE" \
  --network "$NET" \
  -l dev.shinzui.spike=redpanda \
  -l dev.shinzui.spike.role=console \
  -p 127.0.0.1:8080:8080 \
  -e CONFIG_FILEPATH=/tmp/console-config.yaml \
  --entrypoint /bin/sh \
  "$CONSOLE_IMAGE" \
  -c 'cat > /tmp/console-config.yaml <<EOF
kafka:
  brokers: ["<INTERNAL_HOST>:9092"]
schemaRegistry:
  enabled: true
  urls: ["http://<INTERNAL_HOST>:8081"]
redpanda:
  adminApi:
    enabled: true
    urls: ["http://<INTERNAL_HOST>:9644"]
EOF
exec /app/console'
```

Check the exact entrypoint and argument handling against the image — `container run
--entrypoint` overrides the image's entrypoint, and everything after the image name becomes
arguments to it. If the here-document form gives trouble through the argument array, fall
back to the technique `rpk container start` uses, which is a single `echo` of the config
with escaped newlines followed by `; /app/console`.

Then:

```bash
container logs -n 50 "$CONSOLE"
curl -sf http://127.0.0.1:8080 -o /dev/null -w '%{http_code}\n'
open http://127.0.0.1:8080
```

Expected: HTTP 200, and the browser shows Console with one broker and the `spike-test`
topic visible. **Seeing the topic in the browser is the acceptance for this experiment** —
it proves Console reached the broker over the container network using the internal
address.

If Console starts but reports it cannot reach the broker, the internal advertised address
is wrong. Diagnose from inside Console's container:

```bash
container exec "$CONSOLE" getent hosts <INTERNAL_HOST>
```

If that fails, revisit experiment C. If it resolves but Console still cannot connect, the
broker's `internal` listener may not be bound where you think; check with
`container exec "$BROKER" ss -lntp` if the image has `ss`, or re-read the broker logs.

### Step I — persistence

First the weak form:

```bash
container stop "$BROKER"
container start "$BROKER"
# wait for ready again, then:
rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
```

Then the strong form, which is the one that matters:

```bash
container stop "$BROKER"
container delete "$BROKER"
# re-run the exact `container run` command from step E
# wait for ready, then:
rpk topic list --brokers 127.0.0.1:9092
rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
```

Expected: `spike-test` still exists and still yields `hello`. If it does not, the volume is
not holding Redpanda's state — check that the mount target is exactly
`/var/lib/redpanda/data` and inspect what is actually in the volume:

```bash
container run --rm -v "$VOL":/data docker.io/library/alpine:latest ls -la /data
```

### Step J — labels and JSON

```bash
container list --all --format json | jq '.'
container inspect "$BROKER" | jq '.'
container volume list --format json | jq '.'
container network list --format json | jq '.'
```

Record the structures. Specifically identify, and write down in the findings, the `jq`
path to each of: container name, running state, IP address, image reference, and the
labels map. Also determine whether `container list` supports server-side label filtering or
whether filtering must happen in `jq`.

### Step K — tear down

```bash
container stop "$CONSOLE" "$BROKER" || true
container delete "$CONSOLE" "$BROKER" || true
container volume delete "$VOL" || true
container network delete "$NET" || true

container list --all
container volume list
container network list
```

Expected: no `spike-*` resources remain. If you created a DNS domain in experiment C and do
not want to keep it, remove it — but note that plan 3 may want it, so record the decision
rather than reflexively deleting:

```bash
container system dns list
# sudo container system dns delete test
```

Also remove the Alpine test image if you do not want it lingering:

```bash
container image list
# container image delete docker.io/library/alpine:latest
```


## Validation and Acceptance

This plan is complete when `docs/spikes/1-apple-container-redpanda-findings.md` exists,
contains real command output for all ten experiments, and answers these questions
unambiguously:

1. **Which string does one container use to address another?** A literal string, e.g.
   `spike-redpanda-0` or `spike-redpanda-0.test`, or the finding that only IP addresses
   work. Plan 3 renders this verbatim.
2. **Is a `sudo container system dns create <domain>` step required for
   container-to-container resolution?** If yes, plan 4 must include it in the setup runbook,
   because it needs administrator privileges and cannot be done from a `home-manager`
   activation without a password prompt.
3. **Does a named volume mounted at `/var/lib/redpanda/data` preserve topics and messages
   across container deletion and recreation?** Yes or no, with the transcript.
4. **Which readiness check works, and how long does startup take?** The exact URL or command,
   and a rough time-to-ready in seconds. Plan 3's poll loop uses both.
5. **What is the working Console configuration?** The exact YAML and the exact
   `container run` invocation that produced a Console showing the broker and topics.
6. **What is the `jq` path to each field a status script needs?** Container name, state, IP,
   image, labels.
7. **Are the five host ports free and did publishing work for all of them?**
8. **What went wrong that this plan did not anticipate?** Recorded in Surprises &
   Discoveries with evidence.

The behavioural acceptance, which you must have personally observed:

```text
$ echo "hello" | rpk topic produce spike-test --brokers 127.0.0.1:9092
$ rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
{"topic":"spike-test","value":"hello",...}
```

with `colima status` reporting Colima not running, and `http://127.0.0.1:8080` showing
Console listing the broker and the `spike-test` topic.

And the teardown acceptance:

```bash
$ container list --all
$ container volume list
$ container network list
```

show no `spike-` prefixed resources.


## Idempotence and Recovery

Every experiment is repeatable, but `container run --name X` fails if a container named `X`
already exists, even a stopped one. When re-running a step, delete first:

```bash
container stop "$BROKER" 2>/dev/null || true
container delete "$BROKER" 2>/dev/null || true
```

The same applies to networks and volumes: `container network create` and
`container volume create` fail on an existing name. Deleting a volume requires that no
container — running *or stopped* — references it, so delete containers before volumes.

Deleting the volume `spike-redpanda-0-data` destroys the spike's Redpanda data. That is
fine; it is spike data. Just do not confuse it with the real volume that plan 3 creates,
which is named `redpanda-0-data` — another reason for the `spike-` prefix.

If the whole runtime gets into a strange state — containers that will not stop, DNS that
stopped resolving after the machine slept — restart the service:

```bash
container system stop
container system start
```

Record any time you have to do this, and what triggered it. Community reports describe
sleep/wake breaking DNS in exactly this way, and plan 3 needs to know whether to defend
against it.

Nothing in this plan modifies any repository except adding the findings document, and
nothing touches the dotfiles repository at all. There is no rollback to design: if the
spike goes badly, tear down the containers and the machine is as it was.

If the spike's conclusion is that Redpanda cannot work on Apple Container — for example if
container-to-container networking proves unusable — that is a legitimate outcome. Record it
in the Outcomes & Retrospective, mark this plan Complete, and raise it with the MasterPlan:
plans 3 and 4 would then need re-scoping, most likely to a broker-only design with Console
dropped or run differently.


## Interfaces and Dependencies

**Consumed from plan 1**
(`docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md`):

- The `container` binary at 1.2.2 or later, on `PATH`, with its API server running.
- Confirmation that `container network list` works, i.e. macOS 26 user-defined networks are
  available.

**Produced by this plan, consumed by plan 3**
(`docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md`):

- `docs/spikes/1-apple-container-redpanda-findings.md` — the findings document.
- The internal addressing decision (MasterPlan Integration Point 3).
- The verified `container run` argument list for the broker and for Console — plan 3
  renders these from Nix rather than inventing them.
- The verified readiness check and typical startup duration.
- The `jq` paths into `container list`/`container inspect` JSON.

**Produced by this plan, consumed by plan 4**
(`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`):

- Whether a `sudo container system dns create <domain>` step is required, since that must
  appear in the setup runbook.

**External tools used:**

- `container` — Apple Container CLI. Commands used: `image pull`, `image list`,
  `network create|list|inspect|delete`, `volume create|list|inspect|delete`, `run`, `list`,
  `inspect`, `logs`, `exec`, `stop`, `start`, `delete`, `system status|property list|dns`.
- `rpk` v26.2.1 (Homebrew) — `version`, `cluster info`, `cluster metadata`,
  `cluster health`, `topic create|produce|consume|list`. Always with an explicit
  `--brokers 127.0.0.1:9092` in this plan.
- `curl` — Admin API, Schema Registry, HTTP Proxy, and Console probes.
- `jq` — inspecting JSON output.
- `lsof` — port collision check.

**Container images:**

- `docker.redpanda.com/redpandadata/redpanda:v26.2.1`
- `docker.redpanda.com/redpandadata/console:v3.9.0`
- `docker.io/library/alpine:latest` — for the isolated networking and volume experiments.
