---
id: 1
slug: run-redpanda-locally-on-apple-container-via-nix
title: "Run Redpanda locally on Apple Container via Nix"
kind: master-plan
created_at: 2026-08-09T00:14:57Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
---


# Run Redpanda locally on Apple Container via Nix

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Today, running Redpanda on this machine means starting Colima (a Linux virtual machine
that hosts a Docker daemon) and then running `rpk container start`, which drives that
Docker daemon. Colima is slow to boot, holds memory for as long as it runs, and is a
second virtual machine on a Mac that already has Apple's own container runtime available.
The Redpanda CLI itself (`rpk`) comes from Homebrew rather than Nix, so the whole local
Kafka story sits outside the declarative configuration that manages everything else on
this machine.

After this initiative is complete, a single Redpanda broker and a single Redpanda Console
run as Apple Container containers, started at login by a launchd agent that
`home-manager` installs, with all of it declared in Nix. Colima never has to start.
From any directory on the machine — `~/Keikaku/bokuno/mori-project`, a scratch directory,
anywhere — the following works with no per-project setup:

```bash
rpk topic create orders
echo hello | rpk topic produce orders
rpk topic consume orders -n 1
```

and `http://127.0.0.1:8080` shows Redpanda Console listing that topic. Five shell
commands (`redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
`redpanda-purge`) manage the cluster's lifecycle, and broker data survives
`redpanda-down` followed by `redpanda-up` because it lives on a named Apple Container
volume rather than inside the container's writable layer.

Two repositories change. `/Users/shinzui/Keikaku/bokuno/redpanda-container` (this
repository) becomes a Nix flake that exports a `home-manager` module and the wrapper
scripts. `/Users/shinzui/Keikaku/dotfiles.nix` gains a derivation that packages Apple
Container at its latest upstream release, consumes this repository as a flake input, and
imports the module.

### Explicitly in scope

One shared single-broker cluster on fixed, well-known localhost ports (Kafka 9092,
Admin API 9644, Schema Registry 8081, HTTP Proxy 8082, Console 8080). Named-volume data
persistence across restarts. An `rpk` profile so every project's `rpk` invocations reach
the cluster without configuration. Apple Container packaged in Nix at the latest upstream
release (1.2.2 as of 2026-08-08, versus 1.1.0 in nixpkgs). Autostart at login, following
the launchd conventions already documented in
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`.

### Explicitly out of scope

Multi-broker clusters. Per-project isolated clusters. Dynamic or random host port
allocation. A compiled command-line tool of any kind. A runtime abstraction over Docker,
Podman, and Apple Container. Contributions to upstream `rpk`. Removing Colima, Docker, or
the Homebrew `redpanda` formula from the machine — the Colima path stays installed and
working as a fallback, and this initiative only stops *depending* on it.

The reasoning behind each exclusion is recorded in the Decision Log below, because the
source document this initiative grew out of (`docs/initial-spec.md`) specifies all of
them and a future reader will otherwise wonder why they are missing.


## Decomposition Strategy

The initiative was decomposed along the axis of *what must be true before the next piece
can be built*, which in this case produces a short, honest chain rather than a wide fan.

The first concern is **having the runtime at all**. Apple Container is not installed on
this machine and nixpkgs is a minor version behind upstream. Nothing else can be tested
until `container --version` prints the expected version and `container system status`
reports the service running. That is EP-1.

The second concern is **whether Redpanda actually works on this runtime**. Apple Container
is not Docker. Its user-defined networks only exist on macOS 26 and later. Its
container-to-container name resolution goes through an embedded DNS service whose exact
behaviour on user-defined networks is not documented in a way that can be relied on
without testing. Its named volumes exist, but `rpk container start` never used volumes at
all (it relies on the container's writable layer surviving stop/start), so the persistence
path is untested territory for Redpanda specifically. Building a `home-manager` module on
top of unverified assumptions would mean discovering them wrong through launchd logs,
which is a miserable way to debug. So the second work stream is a deliberate throwaway
spike that answers six concrete questions with recorded shell transcripts. That is EP-2.
This mirrors section 36 of `docs/initial-spec.md`, which insists on exactly this
sequencing.

The third concern is **the declarative artifact**: a flake in this repository exporting a
`home-manager` module that renders the verified container invocations into wrapper scripts
and a launchd agent. It is separated from the spike because the spike is disposable
transcript-gathering and the module is durable code, and separated from EP-4 because the
module must be testable in isolation (built and run by hand) before it is wired into the
system configuration where a mistake means a broken `darwin-rebuild switch`. That is EP-3.

The fourth concern is **adoption**: making the machine actually use it. Adding the flake
input, importing the module, generating the `rpk` profile, proving every consuming project
still works, and writing the runbook and rollback path. This is separated from EP-3
because it changes a different repository, has a different failure mode (a bad
`darwin-rebuild switch` affects the whole machine), and is the only work stream that
touches things the user depends on day to day. That is EP-4.

### Alternatives considered and rejected

**A compiled CLI implementing the spec's runtime abstraction.** `docs/initial-spec.md`
describes a `Runtime` interface with Docker, Podman, and Apple implementations, cluster
metadata persistence, capability detection, and dynamic port allocation. Almost all of
that machinery exists because `rpk` must serve every user on every runtime with clusters
of arbitrary size. For one shared single-broker cluster on one runtime with fixed ports,
what remains after deleting the machinery is: create a volume, create a network, run two
containers, wait for readiness, write an `rpk` profile. That is a shell script. The
decision and its reversal criteria are in the Decision Log.

**Putting everything in the dotfiles repository.** Rejected because this repository
already exists for exactly this purpose and because the module is easier to iterate on and
version when it is a flake input, matching the pattern already used for `mori`, `rei`,
`kizamu`, and the other tools in
`/Users/shinzui/Keikaku/dotfiles.nix/flake.nix`.

**Skipping the spike and writing the module directly.** Rejected because three of the six
questions the spike answers (container-to-container DNS on a user-defined network, whether
Console can reach the broker internally, whether a named volume survives container
deletion) directly determine what arguments the module renders. Getting them wrong is not
a small correction; it changes the listener configuration.

**A three-broker cluster.** Rejected because nothing on this machine needs replication
testing today, and a single broker in `dev-container` mode is what the Colima setup
effectively provided. If that changes, the Decision Log records the trigger for revisiting.

### ADR context

There is no `docs/adr/` directory in this repository and none in
`/Users/shinzui/Keikaku/dotfiles.nix`. Neither repository has a `mori.dhall`, so neither
has a profile-governed OKF ADR bundle. A search of the Mori registry for cross-repository
decisions found nothing relevant:

```bash
mori registry search redpanda
# No projects matching 'redpanda'

mori registry concepts --search 'container runtime' --json
# []
```

**No relevant ADR exists.** Two durable decisions from this initiative are strong ADR
candidates and should be promoted to `docs/adr/` in this repository as the work proceeds
— see Integration Points for which plan owns each:

1. *Why there is no compiled CLI, and what would justify building one.* This is the
   decision most likely to be re-litigated by a future reader holding
   `docs/initial-spec.md`, which argues at length for the opposite.
2. *The resource naming, labelling, and host-port contract.* Anything that later inspects,
   cleans up, or coexists with these containers depends on it.

The relevant *conventions* that do exist are documented rather than recorded as ADRs, and
every child plan that needs them restates them inline:
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md` (launchd label scheme
`com.shinzui.<name>`, `RunAtLoad` plus `KeepAlive`, the pre-activation stop-and-wait hook,
the `just status-*` / `restart-*` / `logs-*` recipe families, and the Caddy
`*.localhost` proxy) and
`/Users/shinzui/Keikaku/dotfiles.nix/docs/go-derivations.md`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Package Apple Container at its latest release in Nix | docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md | None | None | In Progress |
| 2 | Spike: prove Redpanda runs on Apple Container | docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md | EP-1 | None | Complete |
| 3 | Build the redpanda-container flake and home-manager module | docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md | EP-2 | EP-1 | Not Started |
| 4 | Adopt the Nix-managed Redpanda across projects and retire the colima path | docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md | EP-3 | EP-1 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The chain is genuinely serial, and that is a property of the problem rather than an
artifact of the decomposition:

```text
EP-1 (Apple Container in Nix)
   │  provides: a working `container` binary at a pinned version
   ▼
EP-2 (Spike)
   │  provides: verified answers about DNS, volumes, ports, networking
   ▼
EP-3 (Flake + home-manager module)
   │  provides: services.redpanda-container module + wrapper scripts
   ▼
EP-4 (Adoption in dotfiles, rpk profile, runbook)
```

**EP-2 hard-depends on EP-1** because the spike runs `container` commands. There is no way
to answer "does a named volume survive container deletion" without the binary. This
dependency could be downgraded to soft by installing the signed `.pkg` from Apple by hand,
but doing so would test a different build than the one that ships, so the plan keeps it
hard and EP-1 is deliberately small enough that this costs little.

**EP-3 hard-depends on EP-2** because EP-2's findings are literal inputs to the module's
output. Specifically, EP-2 decides how the broker advertises its internal listener — a
container DNS name such as `redpanda-0`, a fully qualified name such as
`redpanda-0.test`, or an IP address read back from `container inspect` — and that string
appears verbatim in the `--advertise-kafka-addr` argument the module renders. EP-3 also
soft-depends on EP-1 because the module refers to the `container` package by its overlay
attribute name.

**EP-4 hard-depends on EP-3** because it imports the module EP-3 defines; there is nothing
to import until then. It soft-depends on EP-1 because the dotfiles overlay that EP-1 adds
must already be in place for the module's default `package` to resolve.

**Nothing runs in parallel.** If a second contributor were available, the only genuinely
independent slice is the documentation portion of EP-4 (updating
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md` and writing the runbook),
which can be drafted while EP-3 is in flight and corrected afterwards.


## Integration Points

**1. The `container` package attribute.** EP-1 defines a derivation at
`/Users/shinzui/Keikaku/dotfiles.nix/derivations/apple-container.nix` and exposes it
through the `my-packages` overlay in
`/Users/shinzui/Keikaku/dotfiles.nix/flake-modules/overlays.nix` under the attribute name
`container`, shadowing nixpkgs' own `container` (1.1.0). EP-2 invokes that binary from a
shell. EP-3 must **not** hard-code `pkgs.container`; it exposes a
`services.redpanda-container.package` option so the module works in a checkout that does
not have the dotfiles overlay, and EP-4 sets that option (or relies on the default
resolving through the overlay). EP-1 owns the attribute name; changing it breaks EP-4.

**2. The resource naming and labelling contract.** EP-3 owns these names; EP-2 validates
them; EP-4's purge instructions and runbook depend on them. They are fixed here so all
three plans agree:

```text
network:          redpanda
broker container: redpanda-0
console container: redpanda-console
broker volume:    redpanda-0-data
labels:           dev.shinzui.redpanda.managed=true
                  dev.shinzui.redpanda.role=broker | console
                  dev.shinzui.redpanda.node-id=0        (broker only)
launchd label:    com.shinzui.redpanda
```

The label prefix `dev.shinzui.redpanda.` deliberately differs from `rpk container`'s
own labels (`cluster-id=redpanda`, `node-id=<n>`) so that a cluster started by
`rpk container start` under Docker and a cluster started by this module are never
confused for one another. This contract is the first ADR candidate.

**3. The internal addressing decision — RESOLVED by EP-2 on 2026-08-08.** EP-3 consumes
this; the full evidence is in `docs/spikes/1-apple-container-redpanda-findings.md`.

The broker advertises the **fixed container name** `redpanda-0`, and Console resolves that
name through a hosts file generated on macOS at start time from the broker's discovered IP
and bind-mounted over `/etc/hosts` in Console's container:

```text
--advertise-kafka-addr internal://redpanda-0:9092,external://127.0.0.1:9092
container run ... -v <generated-hosts-file>:/etc/hosts ... <console-image>
```

None of the three candidates originally listed here work. **Container-to-container name
resolution does not exist on Apple Container 1.2.2**: bare names fail, `--dns-domain` alone
fails, and a domain registered with `sudo container system dns create` fails too — that
command writes a *macOS-side* resolver (`/etc/resolver/containerization.test` pointing at
`127.0.0.1:2053`) for resolving containers **from** macOS, not between containers. A raw IP
cannot be used either, because the advertised address is fixed at `container run` time,
before the container has an IP, and because IPs change on every restart.

Two consequences bind EP-3 and EP-4:

- **EP-3 must start things in a strict order**: start the broker, poll it ready, read its IP
  with `container inspect redpanda-0 | jq -r '.[0].status.networks[0].ipv4Address' | cut -d/ -f1`,
  write the hosts file, then start Console. Restarting the broker alone leaves Console
  dialling a dead address; anything that restarts the broker must restart Console too.
- **EP-4 must NOT put a `sudo container system dns create` step in the runbook.** The
  original wording of this integration point anticipated needing one. It is not needed and
  would not help.

**4. The host port contract.** EP-3 owns it as module option defaults; EP-4 consumes it
when generating the `rpk` profile and when deciding whether to add a Caddy entry.

```text
9092  Kafka API           (external listener)
9644  Admin API
8081  Schema Registry     (external listener)
8082  HTTP Proxy          (external listener)
8080  Redpanda Console
```

These ports are checked against everything already listening on this machine per
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md` — VictoriaLogs 9428,
VictoriaTraces 10428, Jaeger 16686, mina 8765, reiko 8770, rei kiroku metrics 9091,
PostgreSQL on a unix socket, Caddy on 80 — and none collide. They also match the ports
already recorded in the existing `rpk-container` profile in
`~/Library/Application Support/rpk/rpk.yaml`, so the profile EP-4 generates is
substitutable for the one Colima's cluster left behind.

**5. The `home-manager` module option schema.** EP-3 defines
`services.redpanda-container.*`; EP-4 sets it from
`/Users/shinzui/Keikaku/dotfiles.nix/home/redpanda.nix`. EP-3 must not rename options
after EP-4 begins without updating EP-4 in the same change.

**6. Deliberate exclusion: the runtime abstraction.** No plan implements one. This is
recorded as an integration point rather than merely a scope note because a future
contributor reading `docs/initial-spec.md` alongside this MasterPlan will otherwise
assume the abstraction was forgotten rather than declined. This is the second ADR
candidate.


## Progress

- [x] EP-1: `derivations/apple-container.nix` builds Apple Container 1.2.2 and `container --version` reports it (2026-08-08)
- [x] EP-1: the overlay exposes it and `home/default.nix` installs it (2026-08-08)
- [x] EP-1: a Linux container runs with Colima stopped, and `container network list` confirms user-defined networks (2026-08-08)
- [ ] EP-1: `container system start` runs at login and `container system status` reports healthy — module activated and verified running against the current derivation (2026-08-08); the login/reboot half is still unverified pending a reboot
- [x] EP-2: image pull, named volume, and port publishing verified with recorded transcripts (2026-08-08)
- [x] EP-2: Redpanda starts in `dev-container` mode and Kafka is reachable from the macOS host (2026-08-08)
- [x] EP-2: container-to-container networking and name resolution verified; internal addressing decided (2026-08-08) — no name resolution exists; bind-mounted `/etc/hosts` chosen
- [x] EP-2: volume persistence across container deletion verified; findings written up (2026-08-08)
- [ ] EP-3: flake skeleton exports `homeManagerModules.redpanda-container`
- [ ] EP-3: module renders `redpanda-up` / `redpanda-down` / `redpanda-status` / `redpanda-logs` / `redpanda-purge`
- [ ] EP-3: launchd agent starts the cluster at login and readiness polling works
- [ ] EP-3: module exercised end to end from a standalone `nix build` / `home-manager` test
- [ ] EP-4: dotfiles consumes the flake input and imports the module; `darwin-rebuild switch` succeeds
- [ ] EP-4: `rpk` profile generated; produce/consume works from at least two unrelated project directories
- [ ] EP-4: Console reachable and showing topics; runbook and rollback documented
- [ ] EP-4: `docs/local-services.md` updated; a full boot with Colima never started is verified


## Surprises & Discoveries

Recorded during research, before implementation began. Each of these shaped the
decomposition above.

**`rpk container start` never used a volume.** Reading
`src/go/rpk/pkg/cli/container/containerutil/common.go` from `redpanda-data/redpanda`
shows the broker container config has no `Binds` and no `Mounts`; data persistence across
`rpk container stop` / `start` works only because the container is not removed. The named
volume this initiative uses is therefore a genuine improvement over the setup being
replaced, and also an untested path — which is why EP-2 tests it explicitly.

**`rpk container start` computes container IPs in advance.** The same file calls
`nodeIP(ctx, c, netID, nodeID)` and passes the resulting IP into
`ListenAddresses`/`AdvertiseAddresses`, relying on Docker's IPAM accepting a
caller-chosen `IPAMConfig.IPv4Address`. Apple Container's `container run` has no
equivalent flag, so that approach is unavailable. The Redpanda quickstart
`docker-compose.yml` uses container *hostnames* (`redpanda-0`) rather than IPs for the
same purpose, which is the approach EP-2 tests first.

**nixpkgs is behind upstream.** `pkgs.container` is 1.1.0; `apple/container` released
1.2.2 on 2026-08-08. The nixpkgs derivation at `pkgs/by-name/co/container/package.nix` is
a thin unpack of the signed installer (`xar -xf $src Payload`, then `bsdtar --extract`),
so bumping is a version-and-hash change. The hash for 1.2.2 was prefetched during
research:

```text
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/apple/container/releases/download/1.2.2/container-1.2.2-installer-signed.pkg
{"hash":"sha256-9MfnP3IDclo1Emdt/Z7GxqmKNwk7b9ShsP3PyyJ+IRg=","storePath":"/nix/store/hxx0blmv5i8s1k19plp4lp2y55780r7z-container-1.2.2-installer-signed.pkg"}
```

**macOS 26 is required and available.** This machine reports `ProductVersion 26.5.2` on
`arm64`. Apple Container's own documentation states user-defined networks
(`container network create`) do not exist on macOS 15 and that containers there cannot
reach each other at all. On macOS 26 both work. Had this machine been on macOS 15, the
entire multi-container design — broker plus Console on a shared network — would have been
impossible and the decomposition would have needed a different Console strategy.

### Discovered during EP-1 (2026-08-08)

**Apple Container's launch agent lives in the `user/<uid>` launchd domain, not `gui/<uid>`.**
Every other service on this machine is a `home-manager` agent in `gui/<uid>` per
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`. Apple Container's is not:
`container system start` writes its own plist to
`~/Library/Application Support/com.apple.container/apiserver/apiserver.plist` and bootstraps it
into `user/<uid>`, so `launchctl print gui/501/com.apple.container.apiserver` fails outright.
EP-3 must keep the two straight: its *own* Redpanda agent is a normal `home-manager` `gui/`
agent, but any code that inspects or waits on the Apple Container API server must use `user/`.

**The API server registration freezes a Nix store path, so package upgrades silently rot it.**
The plist Apple writes hard-codes the store path into both `ProgramArguments[0]` and
`CONTAINER_INSTALL_ROOT`. After the derivation is bumped, the old apiserver keeps running from
the superseded path — giving version skew first and a dead agent once that path is
garbage-collected — and a liveness-only health check never notices, because something *is*
running. EP-1 solved this with an activation hook that compares recorded against desired install
root and re-registers on drift. This is a genuine architectural constraint about self-registering
third-party daemons on an immutable store, and it is a **third ADR candidate** alongside the two
already listed in the ADR context section; it should be written during the completion distillation
pass.

**`container system status` exits 0 when running and 1 when not**, making it a reliable readiness
probe. EP-3's launchd agent should poll it rather than assume the API server is up — which also
covers the sleep/wake unreliability noted below.

**`container network list` has no `STATE` column** on 1.2.2, contrary to what EP-1's validation
section predicted. Actual output is `NETWORK  SUBNET` / `default  192.168.64.0/24`. EP-2 must not
parse for a state column that does not exist.

**`CONTAINER_APP_ROOT` is mutable state outside the Nix store**, at
`~/Library/Application Support/com.apple.container`. Images, volumes, and the installed Linux
kernel live there, not in the store, so it is not reproducible from the flake. EP-4's purge and
rollback instructions must account for it, and EP-2's volume-persistence findings will be about
that directory.

### Discovered during EP-2 (2026-08-08)

Full transcripts in `docs/spikes/1-apple-container-redpanda-findings.md`.

**Container-to-container name resolution does not exist, so the "embedded DNS" note below
is superseded.** It is not merely thin — it is absent. This invalidated the assumption,
carried in the pre-implementation note below and in Integration Point 3, that one of several
name forms would work. See the resolved Integration Point 3 for the mechanism EP-3 must use
instead.

**Apple Container's networking degrades and a runtime restart repairs it.** Container-to-
container connectivity that had been demonstrated working stopped working entirely, then was
fully restored by `container system stop && container system start`. The obvious hypothesis
— that publishing ports caused it — was tested and disproved. This affects EP-3 (verify
connectivity, do not assume it) and EP-4 (document the restart as the remedy).

**The Redpanda image needs its volume chowned to `101:101`.** The image runs as
`uid=101(redpanda)`; a fresh Apple Container named volume mounts root-owned and masks the
image's data directory, killing the broker at startup. EP-3 must chown as part of volume
creation. This is new information for Integration Point 2, which named the volume but said
nothing about its ownership.

**Images must be pulled from Docker Hub with an explicit `--platform linux/arm64`.**
`docker.redpanda.com` rate-limited persistently (HTTP 429), and Apple Container selected the
`linux/amd64` variant of the multi-arch image on this arm64 machine, which would run the
broker under emulation. EP-3 must render both the registry and the platform flag.

**Console must be restarted whenever the broker restarts**, because broker IPs change on
every restart and the generated hosts file freezes the IP at Console start time. This makes
"restart the broker" an unsupported standalone operation and constrains EP-3's script design.

**`container` JSON has no server-side label filtering**, so EP-3's `redpanda-status` and
`redpanda-purge` must list everything and filter `.configuration.labels` with `jq`. The
useful paths are `.configuration.id`, `.status.state`,
`.status.networks[0].ipv4Address`, `.configuration.image.reference`, and
`.configuration.labels`.

### Recorded before implementation began

**Apple Container has an embedded DNS service, but its guarantees are thin.** (Superseded by
EP-2 — resolution does not work at all; see above.) The
`container` tutorial shows `container run -it --rm web-test curl http://my-web-server.test`
resolving one container from another after `sudo container system dns create test`, and
`container run` accepts `--dns-domain`. Community reports describe container-to-container
resolution working for both `db.testdomain` and the bare name `db`, and also describe DNS
becoming unreliable after host sleep/wake until `container system stop && container system
start`. EP-2 must verify the behaviour and EP-3's launchd agent should tolerate the
sleep/wake failure mode rather than assume it away.


## Decision Log

- Decision: Build no compiled CLI. This repository ships a Nix flake exporting a
  `home-manager` module plus generated shell wrappers, not a Go or Haskell binary.
  Rationale: `docs/initial-spec.md` argues for a runtime abstraction over Docker, Podman,
  and Apple Container with cluster metadata, capability detection, and dynamic port
  allocation. Every one of those exists to serve constraints `rpk` has and this machine
  does not: multiple runtimes, arbitrary cluster sizes, and clusters created by one
  invocation and managed by another. With one runtime, one shared single-broker cluster,
  and fixed ports, what remains is four `container` invocations, a readiness poll, and an
  `rpk` profile write — which is a shell script, and which matches the pattern
  `home/postgresql.nix` and `home/victorialogs.nix` already use in the dotfiles
  repository. Reversal criteria, recorded so this is not re-litigated from memory: build
  the compiled tool when multi-broker clusters, per-project isolated clusters, or dynamic
  port allocation is actually needed. At that point the shell approach starts requiring
  port-collision handling, seed-server bootstrapping, and JSON parsing of
  `container inspect`, and a real tool with unit-testable argument construction wins.
  Date: 2026-08-08

- Decision: One shared long-lived cluster, not per-project clusters.
  Rationale: this directly replaces the existing Homebrew-Redpanda-on-Colima setup, which
  was also a single shared instance. Per-project clusters would multiply memory use across
  concurrently open projects and force dynamic port allocation, and no current project
  needs isolation from another's topics.
  Date: 2026-08-08

- Decision: Single broker, not three.
  Rationale: nothing on this machine tests replication or partition rebalancing today, and
  `--mode dev-container` is explicitly a development configuration. Revisit if a project
  needs to test replica placement or broker failure.
  Date: 2026-08-08

- Decision: Keep Colima, Docker, and the Homebrew `redpanda` formula installed.
  Rationale: this initiative removes the *dependency* on Colima for Redpanda, not Colima
  itself. `rpk` from Homebrew is what generates and reads the `rpk` profile and is
  currently at v26.2.1, matching the `docker.redpanda.com/redpandadata/redpanda:v26.2.1`
  image; replacing it with a nixpkgs build is a separate decision with its own version-skew
  risk. Colima remains as a fallback if the Apple Container path proves unreliable, and
  other tooling may still use the Docker socket exported by `DOCKER_HOST` in
  `/Users/shinzui/Keikaku/dotfiles.nix/home/zsh.nix`. Retiring either is a follow-up that
  should be decided after this has run for a while.
  Date: 2026-08-08

- Decision: Package Apple Container in the dotfiles repository rather than waiting for
  nixpkgs, and pin it explicitly.
  Rationale: nixpkgs ships 1.1.0 against upstream 1.2.2, and the requirement was
  explicitly for the latest version. The nixpkgs derivation is a thin installer unpack, so
  carrying a local copy pinned to a chosen version is low-cost and makes the version an
  explicit, reviewable fact rather than whatever nixpkgs-unstable happens to hold.
  Date: 2026-08-08

- Decision: Insert a throwaway spike (EP-2) between packaging and building.
  Rationale: three assumptions the module depends on — container-to-container DNS on a
  user-defined network, named-volume persistence across container deletion, and Console
  reaching the broker internally — are not reliably documented and are expensive to debug
  once buried inside a launchd agent. Section 36 of `docs/initial-spec.md` argues for the
  same sequencing. The spike's output is recorded transcripts and a decision on internal
  addressing; its code is discarded.
  Date: 2026-08-08

- Decision: Decompose into four child plans along a serial chain rather than forcing
  parallelism.
  Rationale: each stage produces the input the next stage consumes, and the two candidate
  parallel splits both fail on inspection. Splitting EP-1 into "derivation" and "launchd
  agent" produces a plan too small to verify independently, and splitting EP-3 into
  "module options" and "wrapper scripts" splits a single file down the middle, which the
  decomposition principles in `agents/skills/master-plan/MASTERPLAN.md` warn against.
  Date: 2026-08-08

- Decision: Fix the resource naming, labelling, and host-port contract in this MasterPlan
  rather than letting EP-3 choose it.
  Rationale: EP-2 validates the names, EP-3 renders them, and EP-4's purge and runbook
  instructions reference them. Three plans must agree, which is precisely what the
  Integration Points section exists for.
  Date: 2026-08-08


## Outcomes & Retrospective

(To be filled during and after implementation.)
