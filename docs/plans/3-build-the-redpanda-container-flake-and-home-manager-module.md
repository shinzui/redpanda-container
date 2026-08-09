---
id: 3
slug: build-the-redpanda-container-flake-and-home-manager-module
title: "Build the redpanda-container flake and home-manager module"
kind: exec-plan
created_at: 2026-08-09T00:15:02Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
master_plan: "docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md"
---


# Build the redpanda-container flake and home-manager module

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plan 2 proved by hand that a Redpanda broker and a Redpanda Console can run on Apple
Container. This plan turns those hand-typed commands into a declarative, reusable artifact:
a Nix flake in this repository that exports a `home-manager` module.

After this plan, this repository is a flake. Anyone — in practice, the dotfiles repository
in plan 4 — can add it as an input and write:

```nix
{
  imports = [ inputs.redpanda-container.homeManagerModules.default ];
  services.redpanda-container.enable = true;
}
```

and get five commands on their `PATH` plus a launchd agent that starts the cluster at
login:

```bash
$ redpanda-up
Creating volume redpanda-0-data...
Creating network redpanda...
Starting broker redpanda-0...
Waiting for Redpanda to become ready...
Starting console redpanda-console...
Redpanda is ready.

  Kafka            127.0.0.1:9092
  Admin API        127.0.0.1:9644
  Schema Registry  127.0.0.1:8081
  HTTP Proxy       127.0.0.1:8082
  Console          http://127.0.0.1:8080

$ redpanda-status
NAME               ROLE     STATE    ADDRESS
redpanda-0         broker   running  127.0.0.1:9092
redpanda-console   console  running  http://127.0.0.1:8080

$ redpanda-down       # stops containers, keeps data
$ redpanda-logs       # tails broker logs
$ redpanda-purge      # removes everything including data, after confirmation
```

This plan does **not** wire the module into the system configuration — that is plan 4's
job, and keeping them separate means a mistake here cannot break `darwin-rebuild switch`.
Everything here is verified by building and running the module's output directly.

This is child plan 3 of the MasterPlan at
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`.


## Progress

- [ ] Read `docs/spikes/1-apple-container-redpanda-findings.md` and transcribe its verified commands
- [ ] Create `flake.nix` with `nixpkgs` and `flake-parts` inputs and an `aarch64-darwin` system
- [ ] Define the module skeleton at `modules/home/redpanda-container.nix` with its options
- [ ] Implement the `redpanda-up` wrapper, including readiness polling
- [ ] Implement `redpanda-down`, `redpanda-status`, `redpanda-logs`, `redpanda-purge`
- [ ] Implement the launchd agent and its pre-activation stop-and-wait hook
- [ ] Export `homeManagerModules.default` and a `packages.<system>.redpanda-scripts` for testing
- [ ] Build the scripts standalone with `nix build` and run each one by hand
- [ ] Verify produce/consume, Console, persistence, and purge against the module's own output
- [ ] Write the README explaining what the flake provides and how to consume it
- [ ] Create `docs/adr/` and record the two ADRs this initiative owns
- [ ] Record findings, decisions, and the retrospective in this plan


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Ship a `home-manager` module rather than a package of scripts alone.
  Rationale: the cluster needs a launchd agent to start at login, and launchd agents on
  this machine are declared through `home-manager`'s `launchd.agents` option. A bare
  package could not provide that. A module also gives the consumer typed options with
  defaults instead of environment variables.
  Date: 2026-08-08

- Decision: Expose the Apple Container package as an option (`package`) rather than
  referring to `pkgs.container` directly.
  Rationale: MasterPlan Integration Point 1. `pkgs.container` in plain nixpkgs is version
  1.1.0; the dotfiles overlay from plan 1 shadows it with 1.2.2. Making it an option means
  this flake works in a checkout without that overlay, and makes the version an explicit
  choice at the consumer rather than an accident of overlay ordering.
  Date: 2026-08-08

- Decision: Generate the wrapper scripts with `pkgs.writeShellApplication` rather than
  `pkgs.writeShellScriptBin`.
  Rationale: `writeShellApplication` sets `set -euo pipefail` for you, takes a
  `runtimeInputs` list that it puts on `PATH` (so the scripts do not need store paths
  interpolated at every call site), and runs `shellcheck` at build time, which catches
  quoting bugs before they reach launchd. The repository being consumed by
  (`/Users/shinzui/Keikaku/dotfiles.nix`) uses `writeShellScript` and
  `writeShellScriptBin` in places, but those predate the need and do not lint.
  Revisit if `shellcheck` proves obstructive.
  Date: 2026-08-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### Where you are

This plan's work happens in `/Users/shinzui/Keikaku/bokuno/redpanda-container`, the
repository this plan file lives in. Its current contents are just documentation and the
planning skills:

```text
.gitignore
.seihou/          seihou module manifests, not relevant here
agents/skills/    the exec-plan and master-plan skills
docs/initial-spec.md
docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
docs/plans/1..4-*.md
docs/spikes/1-apple-container-redpanda-findings.md   (created by plan 2)
```

There is no `flake.nix`, no source code, and no build system yet. This plan creates them.

`docs/initial-spec.md` is the document that started the initiative. It proposes adding
Apple Container support to Redpanda's own `rpk` tool, with a runtime abstraction over
Docker, Podman, and Apple Container. **That is not what this repository builds.** The
MasterPlan's Decision Log explains why: nearly all of that specification's machinery exists
to serve constraints `rpk` has and this machine does not. Read `docs/initial-spec.md` for
background on Redpanda's listener model and for its section 30 networking checklist, but do
not treat it as this plan's specification.

### The single most important input: the spike findings

**Read `docs/spikes/1-apple-container-redpanda-findings.md` before writing any code.** Plan
2 exists to produce it. It contains, verified by hand:

- The exact string one container uses to address another (a bare container name such as
  `redpanda-0`, a name qualified by a DNS domain such as `redpanda-0.test`, or the finding
  that only IP addresses work).
- Whether a `sudo container system dns create <domain>` step is required.
- The exact working `container run` argument list for the broker and for Console.
- The working readiness check and roughly how long startup takes.
- The `jq` paths into `container list --format json` and `container inspect` output for
  name, state, IP, image, and labels.

This plan's job is largely to render those verified commands from Nix. Where this plan and
the findings disagree, **the findings win** — they were observed, this plan was written in
advance. Record any such disagreement in Surprises & Discoveries.

If the findings report that only IP addresses work for container-to-container addressing,
the design changes materially: `redpanda-up` must start the broker, run `container
inspect` to learn its IP, and only then start Console with that IP in its configuration.
The broker's own `--advertise-kafka-addr internal://...` would also need the IP, which
means either restarting the broker after learning its IP or accepting that Console is the
only internal client and pointing it at the IP while the broker advertises something else.
Work that out against the findings; do not guess.

### What a home-manager module is

`home-manager` is the tool that manages this user's dotfiles, packages, and per-user
services declaratively. A *module* is a Nix file that declares `options` (typed settings
with defaults and documentation) and `config` (what to actually do, computed from those
options). A module is a function taking an attribute set — conventionally
`{ config, lib, pkgs, ... }` — and returning `{ options = ...; config = ...; }`.

The two `config` mechanisms this module uses:

- `home.packages` — a list of packages to install into the user's profile, putting their
  `bin/` on `PATH`.
- `launchd.agents.<name>` — declares a macOS launchd agent. `launchd` is macOS's service
  manager; a *launch agent* is a per-user background service described by a plist file.
  `home-manager` writes the plist and registers it.

For worked examples in the repository that will consume this module, read
`/Users/shinzui/Keikaku/dotfiles.nix/home/victorialogs.nix` (a server plus many small
agents, and the stop-and-wait activation hook) and
`/Users/shinzui/Keikaku/dotfiles.nix/home/postgresql.nix` (a service with helper scripts).

### Launchd conventions this module must follow

Documented at `/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`:

- Labels are `com.shinzui.<name>`. This module uses `com.shinzui.redpanda`.
- Agents set `RunAtLoad = true` so they start at login.
- Long-running servers set `KeepAlive = true` so they restart on crash. **This module's
  agent is different**: it is a one-shot that runs `redpanda-up` and exits, because the
  actual long-running processes are the containers, which Apple Container's own service
  supervises. `KeepAlive = true` on a script that exits successfully makes launchd restart
  it in a tight loop. Use `RunAtLoad = true` with `KeepAlive = false`. If you want crash
  recovery, the correct shape is `KeepAlive = { SuccessfulExit = false; }`, which restarts
  only on non-zero exit — decide deliberately and record it.
- Each module installs a `home.activation` hook running before `setupLaunchAgents` that
  stops the old agent and waits for its process to exit by PID, because `launchctl bootout`
  returns before the process is gone and the following `bootstrap` then fails with I/O
  error code 5. The implementation is copied between modules; take it from
  `home.activation.victorialogs-stop-agents` in
  `/Users/shinzui/Keikaku/dotfiles.nix/home/victorialogs.nix`. Note it compares the new and
  current plists and skips the stop when unchanged, and that it uses `awk` rather than
  `grep` to extract the PID specifically so that a loaded-but-not-running agent does not
  make the hook exit non-zero under `set -euo pipefail`.
- Logs go to files under a per-service directory; the shippers in `victorialogs.nix` tail
  known paths. This module writes to `~/.local/state/redpanda/logs/`. Whether to add a
  VictoriaLogs shipper entry is plan 4's decision, not this plan's.

### The naming and port contract

Fixed in the MasterPlan's Integration Points section. This module owns these as option
defaults; plan 4 consumes them. Do not change them here without updating the MasterPlan and
plan 4 in the same commit.

```text
network:            redpanda
broker container:   redpanda-0
console container:  redpanda-console
broker volume:      redpanda-0-data
launchd label:      com.shinzui.redpanda
labels:             dev.shinzui.redpanda.managed=true
                    dev.shinzui.redpanda.role=broker | console
                    dev.shinzui.redpanda.node-id=0     (broker only)

host ports:  9092 Kafka · 9644 Admin · 8081 Schema Registry · 8082 HTTP Proxy · 8080 Console
data dir in container:  /var/lib/redpanda/data
state dir on host:      ~/.local/state/redpanda
```

The `dev.shinzui.redpanda.` label prefix deliberately differs from `rpk container start`'s
labels (`cluster-id=redpanda`, `node-id=<n>`) so a Docker-based cluster and this one are
never confused. `redpanda-purge` must filter on this prefix so it can never delete
someone else's containers.

### The Redpanda invocation, for reference

The broker command line, in the form plan 2 verifies. `<INTERNAL_HOST>` is the string the
findings prove works.

```text
redpanda start
  --node-id 0
  --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092
  --advertise-kafka-addr internal://<INTERNAL_HOST>:9092,external://127.0.0.1:9092
  --pandaproxy-addr internal://0.0.0.0:8082,external://0.0.0.0:18082
  --advertise-pandaproxy-addr internal://<INTERNAL_HOST>:8082,external://127.0.0.1:8082
  --schema-registry-addr internal://0.0.0.0:8081,external://0.0.0.0:18081
  --rpc-addr 0.0.0.0:33145
  --advertise-rpc-addr <INTERNAL_HOST>:33145
  --mode dev-container
  --smp 1
  --default-log-level=info
```

Why the two-listener split exists: a Kafka client connects, asks the broker for metadata,
and then connects to whatever addresses the broker advertises. Console runs in a container
where `127.0.0.1` means Console itself, so it must be told the broker is at
`<INTERNAL_HOST>:9092`. `rpk` runs on macOS where the container network address is not what
you want to depend on, so it must be told `127.0.0.1:9092`, which works because container
port 19092 is published to host port 9092. Each listener advertises the address that is
correct from the perspective of clients arriving on it. The invariant: never advertise
`localhost` to another container, never advertise a container-network address to a macOS
client.

`--mode dev-container` turns on development settings — overprovisioning, zero reserved
memory, disabled system checks, relaxed fsync — which is what lets Redpanda start on a
laptop with one core.

### Apple Container commands the scripts use

- `container volume create <name>` / `volume list --format json` / `volume delete <name>`
- `container network create <name>` / `network list --format json` / `network delete <name>`
- `container run -d --name <n> --network <net> -v <vol>:<path> -p <hostip>:<hostport>:<cport> -l k=v -c <cpus> -m <mem> <image> <args...>`
- `container list --all --format json`
- `container inspect <name>`
- `container logs [--follow] [-n <lines>] [--boot] <name>`
- `container start <name>` / `container stop <name>` / `container delete <name>`
- `container system status`

Behaviours that shape the scripts: `container run --name X` fails if any container named
`X` exists, even stopped — so `redpanda-up` must distinguish "does not exist" (run it) from
"exists but stopped" (start it) from "already running" (do nothing). `container volume
create` and `container network create` fail if the name exists — so create must be
conditional or its failure tolerated. A volume cannot be deleted while any container,
running or stopped, references it — so `redpanda-purge` must delete containers before
volumes. Published ports forward to the IP of the container's **first** network, so each
container attaches to exactly one.

### ADR context

Neither this repository nor `/Users/shinzui/Keikaku/dotfiles.nix` has a `docs/adr/`
directory, and neither has a `mori.dhall`, so neither has a profile-governed OKF ADR bundle
and no `okf` validation applies. A Mori registry search found no relevant cross-repository
decisions:

```bash
$ mori registry search redpanda
No projects matching 'redpanda'
$ mori registry concepts --search 'container runtime' --json
[]
```

**No relevant ADR exists yet.** This plan creates the repository's first two, because both
are durable decisions that outlive it and that a future reader holding
`docs/initial-spec.md` will otherwise re-litigate:

1. **Why there is no compiled CLI, and what would justify one.** The rationale and the
   reversal criteria are in the MasterPlan's Decision Log; promote them.
2. **The resource naming, labelling, and host-port contract.** Anything that later
   inspects, cleans up, or coexists with these containers depends on it.

Since there is no ADR bundle, follow `agents/skills/exec-plan/ADR.md`'s guidance for a
repository with no established convention: create `docs/adr/` as plain Markdown files, one
decision per file, with a short frontmatter block carrying `title`, `status`, and `date`.
Do **not** invent OKF frontmatter or a Mori identity as an incidental edit — adopting the
shared profile is separate work.

### Toolchain

This machine has Determinate Nix 3.17.0 with flakes enabled. The dotfiles flake uses
`flake-parts`, and following that convention here keeps the two consistent, but a plain
flake is acceptable for something this small — decide and record it. The system is
`aarch64-darwin`; Apple Container only exists there, so the flake should not claim to
support other systems.


## Plan of Work

Four milestones. Each leaves something you can run.

### Milestone 1 — The flake skeleton

At the end of this milestone `nix flake check` passes on a flake that exports nothing
useful yet, which means the scaffolding is right before any logic depends on it.

Create `flake.nix` in the repository root with a `nixpkgs` input following
`nixpkgs-unstable` (matching the dotfiles repository's primary input, so the same package
set is in play), and outputs for `aarch64-darwin` only. Export a placeholder
`homeManagerModules.default` pointing at `modules/home/redpanda-container.nix` and an empty
`packages`. Add a `.gitignore` entry for `result` and `result-*` (the symlinks `nix build`
creates); the existing `.gitignore` covers `.claude/`, `.agents/`, `.seihou/manifest.json.tmp`,
and `CLAUDE.local.md` and needs these added.

Decide here whether to use `flake-parts` or a plain flake, and record it in the Decision
Log. A plain flake for a single-system, two-output repository is defensible; `flake-parts`
matches the consumer.

### Milestone 2 — The module's options

At the end of this milestone the module evaluates, declares every option, and produces no
`config` yet. You can check it evaluates by building a trivial derivation that depends on
the evaluated config, or by pointing a scratch `home-manager` configuration at it.

Create `modules/home/redpanda-container.nix`. Declare `options.services.redpanda-container`
with, at minimum:

- `enable` — `lib.mkEnableOption "a local Redpanda cluster running on Apple Container"`.
- `package` — the Apple Container package. `lib.mkPackageOption pkgs "container" { }` or an
  explicit `mkOption` with `type = lib.types.package`. This is MasterPlan Integration
  Point 1; do not hard-code `pkgs.container`.
- `redpandaImage` / `consoleImage` — strings, defaulting to
  `docker.redpanda.com/redpandadata/redpanda:v26.2.1` and
  `docker.redpanda.com/redpandadata/console:v3.9.0`. Pin versions rather than `latest` so a
  rebuild is reproducible; the broker version matches the installed `rpk` v26.2.1.
- `enableConsole` — bool, default true.
- `network`, `brokerName`, `consoleName`, `volumeName` — strings with the contract defaults.
- `internalHost` — the string the broker advertises internally. Default it to the value the
  spike findings proved. Make it an option rather than a constant because if it turns out to
  depend on a DNS domain that the user must create with `sudo`, the consumer may need to
  change it.
- `dnsDomain` — nullable string, passed as `--dns-domain` when set. Default `null` unless
  the findings require otherwise.
- `ports` — a submodule with `kafka` (9092), `admin` (9644), `schemaRegistry` (8081),
  `proxy` (8082), `console` (8080).
- `hostAddress` — string, default `127.0.0.1`, used as the host IP in `--publish` and as the
  externally advertised address. Making this an option documents *why* `127.0.0.1` appears
  in two unrelated-looking places.
- `cpus` / `memory` — resources for the broker container; defaults `2` and `"2G"`, adjusted
  to whatever the spike found actually works.
- `stateDir` — default `"${config.home.homeDirectory}/.local/state/redpanda"`.
- `autoStart` — bool, default true. When false, install the scripts but no launchd agent.
- `readyTimeoutSeconds` — int, default generously above whatever the spike measured.

Write real `description` strings. They are the documentation a reader gets from
`home-manager` and they are cheap to write while the reasoning is fresh.

### Milestone 3 — The five wrapper scripts

At the end of this milestone `nix build .#redpanda-scripts` produces the five commands and
you can run each by hand, without any `home-manager` involvement, and get a working
cluster.

Build them with `pkgs.writeShellApplication`, which sets `set -euo pipefail`, puts
`runtimeInputs` on `PATH`, and runs `shellcheck` at build time. `runtimeInputs` needs at
least the Apple Container package, `jq`, `curl`, and `coreutils`.

**`redpanda-up`** — idempotent bring-up. In order: check the Apple Container service is
responding (`container system status`) and fail with an actionable message if not; create
the volume if absent; create the network if absent; then for the broker, branch on its
state — absent means `container run` with the full argument list, existing-but-stopped
means `container start`, running means report and continue; poll the readiness endpoint the
spike identified until it succeeds or `readyTimeoutSeconds` elapses; then the same
three-way branch for Console if `enableConsole`; finally print the address summary shown in
Purpose.

The failure path matters as much as the success path. If the broker does not become ready
in time, print its last log lines and the command to see more, rather than a bare timeout:

```text
Redpanda did not become ready within 120s.

Last 30 log lines from redpanda-0:
<lines>

For more:
    container logs redpanda-0
    container logs --boot redpanda-0
```

`container logs --boot` shows the VM boot log rather than application stdio and is what you
need when the container died before Redpanda printed anything.

**`redpanda-down`** — stop the containers, keep everything else. Stop Console first, then
the broker, so Console does not spend its shutdown window reconnecting. Tolerate a missing
or already-stopped container silently. **Must not** delete containers, the volume, or the
network — `redpanda-up` afterwards must restore the same data.

**`redpanda-status`** — read `container list --all --format json`, filter to this module's
labels, and print a small table: name, role, state, and the host-side address for each.
Additionally probe readiness and report whether the broker is actually serving, since a
container can be `running` while Redpanda is still starting or has wedged. Exit non-zero
when the broker is not running, so the command is usable in scripts and in a `just` recipe.

**`redpanda-logs`** — thin wrapper over `container logs`. Accept an optional container name
argument defaulting to the broker, pass through `-f`/`--follow` and `-n`, and support
`--boot`. Do not reimplement `container logs`; just make the common case short.

**`redpanda-purge`** — destructive, so it must be careful and idempotent. Prompt for
confirmation unless `--force`/`-f` is given (the launchd agent never calls this, so an
interactive prompt is fine). Then, in this order: stop Console, stop the broker, delete
Console, delete the broker, delete the volume, delete the network. **The order is
mandatory** — a volume cannot be deleted while any container, running or stopped,
references it. Every step tolerates the resource being absent, so running `redpanda-purge`
twice succeeds both times, and so a purge that failed halfway can be finished by running it
again. Filter strictly on the `dev.shinzui.redpanda.` label prefix so it can never touch
containers it did not create. Print what it removed.

Also export these as `packages.aarch64-darwin.redpanda-scripts` — a `symlinkJoin` or
`buildEnv` over the five — so they can be built and tested without `home-manager`. This is
what makes Milestone 3 independently verifiable, and it is worth the three extra lines.

### Milestone 4 — The launchd agent, the module's config, and the ADRs

At the end of this milestone the module is complete and has been exercised through
`home-manager` rather than by hand.

Fill in the module's `config` block, guarded by `lib.mkIf cfg.enable`: put the five scripts
into `home.packages`; create the state and log directories with a `home.activation` hook
using `lib.hm.dag.entryAfter [ "writeBoundary" ]` (copy the shape of
`home.activation.victorialogs-init`); declare `launchd.agents.redpanda` when
`cfg.autoStart`, with label `com.shinzui.redpanda`, `ProgramArguments` invoking
`redpanda-up`, `RunAtLoad = true`, `StandardOutPath` and `StandardErrorPath` under the log
directory, and the `KeepAlive` decision from Context and Orientation; and add the
stop-and-wait pre-activation hook adapted from `victorialogs-stop-agents`.

One wrinkle to think through and record: the launchd agent runs at login, possibly before
Apple Container's own `container-apiserver` agent is up. `redpanda-up`'s first action is a
`container system status` check, so make that check *wait* — poll for a bounded time rather
than failing immediately — otherwise every login is a race. Plan 1's findings on whether
the API server survives reboot are relevant here; if it does not start automatically at
all, `redpanda-up` should say so clearly rather than hanging.

Write `README.md` at the repository root: what the flake provides, the input snippet, the
option list, the five commands, and a pointer to the MasterPlan for the reasoning.

Finally, create `docs/adr/` and write the two ADRs described in ADR context above. Do this
before marking the plan complete, per the distillation requirement.

Testing the module through `home-manager` without touching the real system configuration:
build a scratch `home-manager` configuration in this flake that imports the module and
evaluates against this user, and build its `activationPackage`. That proves the module
composes without running `darwin-rebuild switch`, which is plan 4's risk to take.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/redpanda-container`.

### Step 1 — read the findings

```bash
cd /Users/shinzui/Keikaku/bokuno/redpanda-container
$PAGER docs/spikes/1-apple-container-redpanda-findings.md
```

Extract and write down: the internal host string, whether a DNS domain is needed, the
readiness check, the broker `container run` arguments, the Console configuration, and the
`jq` paths. These are your inputs.

### Step 2 — flake skeleton

```bash
$EDITOR flake.nix
$EDITOR .gitignore     # add: result, result-*
git add flake.nix .gitignore
nix flake check
```

`nix flake check` must pass. Note it needs the files to be tracked by git — an untracked
`flake.nix` is invisible to Nix's flake evaluation, which produces a confusing "path does
not exist" error. That is why `git add` comes before the check.

Commit:

```bash
git commit -m "feat: add flake skeleton for the redpanda-container module

MasterPlan: docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
ExecPlan: docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md
Intention: intention_01kzhxfhpqekma79h936t7t2pk"
```

Every commit in this plan carries those three trailers.

### Step 3 — module options

```bash
mkdir -p modules/home
$EDITOR modules/home/redpanda-container.nix
git add modules/home/redpanda-container.nix
nix flake check
```

### Step 4 — the scripts

```bash
$EDITOR modules/home/redpanda-container.nix     # add the writeShellApplication definitions
git add -A
nix build .#redpanda-scripts --print-out-paths
ls -la result/bin/
```

Expected: `redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
`redpanda-purge`. If the build fails on `shellcheck` warnings, fix the shell rather than
disabling the check — the warnings it emits for this kind of script are almost always real
quoting bugs.

### Step 5 — run them by hand

Make sure nothing is already using the ports, and that no spike leftovers remain:

```bash
container list --all
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9092|9644|8081|8082|8080)\b'
```

Then:

```bash
./result/bin/redpanda-up
```

Expected output resembles the transcript in Purpose. Then prove it actually works:

```bash
rpk cluster info --brokers 127.0.0.1:9092
rpk topic create module-test --brokers 127.0.0.1:9092
echo "from the module" | rpk topic produce module-test --brokers 127.0.0.1:9092
rpk topic consume module-test -n 1 --brokers 127.0.0.1:9092
```

Expected: a JSON record whose `value` is `from the module`.

```bash
./result/bin/redpanda-status
open http://127.0.0.1:8080
```

Expected: the status table, and Console in the browser showing the broker and
`module-test`.

Idempotence — run `redpanda-up` a second time:

```bash
./result/bin/redpanda-up
```

Expected: it reports things already exist and running, changes nothing, exits 0.

Persistence:

```bash
./result/bin/redpanda-down
./result/bin/redpanda-status          # expect non-zero exit, containers stopped
./result/bin/redpanda-up
rpk topic consume module-test -n 1 --brokers 127.0.0.1:9092
```

Expected: the message is still there.

Logs:

```bash
./result/bin/redpanda-logs -n 20
./result/bin/redpanda-logs redpanda-console -n 20
```

Purge, twice:

```bash
./result/bin/redpanda-purge
./result/bin/redpanda-purge --force
container list --all
container volume list
container network list
```

Expected: the first prompts and removes everything; the second succeeds with nothing to do;
no `redpanda` resources remain.

### Step 6 — the module config and launchd agent

```bash
$EDITOR modules/home/redpanda-container.nix
git add -A
nix flake check
```

Then build the scratch `home-manager` configuration to prove the module composes:

```bash
nix build .#homeConfigurations.test.activationPackage --print-out-paths
```

Inspect the generated plist rather than trusting it:

```bash
cat result/home-files/Library/LaunchAgents/com.shinzui.redpanda.plist
```

Check the label, `RunAtLoad`, the `KeepAlive` value you chose, the program path pointing
into the Nix store, and the log paths.

### Step 7 — README and ADRs

```bash
$EDITOR README.md
mkdir -p docs/adr
$EDITOR docs/adr/1-no-compiled-cli-for-local-redpanda.md
$EDITOR docs/adr/2-redpanda-container-naming-and-port-contract.md
git add -A
```

### Step 8 — final commit

```bash
git commit -m "feat: home-manager module for local Redpanda on Apple Container

Adds the redpanda-container flake exporting homeManagerModules.default,
five lifecycle wrappers, and a launchd agent for autostart. Records the
no-CLI decision and the naming/port contract as ADRs.

MasterPlan: docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
ExecPlan: docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md
Intention: intention_01kzhxfhpqekma79h936t7t2pk"
```


## Validation and Acceptance

Acceptance is behavioural and must be demonstrated against the module's own build output,
not against hand-typed commands.

**The flake evaluates and builds.**

```bash
$ nix flake check
$ nix build .#redpanda-scripts
$ ls result/bin/
redpanda-down  redpanda-logs  redpanda-purge  redpanda-status  redpanda-up
```

**A cluster comes up from a clean machine state.** With no `redpanda` containers, volumes,
or networks present:

```bash
$ ./result/bin/redpanda-up
...
Redpanda is ready.
```

exits 0.

**Kafka works from macOS.**

```bash
$ rpk topic create module-test --brokers 127.0.0.1:9092
$ echo "from the module" | rpk topic produce module-test --brokers 127.0.0.1:9092
$ rpk topic consume module-test -n 1 --brokers 127.0.0.1:9092
{"topic":"module-test","value":"from the module",...}
```

**Console reaches the broker over the container network.** `http://127.0.0.1:8080` in a
browser shows one broker and the `module-test` topic. This is the proof that the internal
advertised address is right; a Console that loads but shows no brokers means it is wrong.

**The other services respond.**

```bash
$ curl -s http://127.0.0.1:8081/subjects
[]
$ curl -s http://127.0.0.1:8082/topics
[...,"module-test",...]
```

**`redpanda-up` is idempotent.** Running it twice in a row succeeds both times and the
second run creates nothing.

**Data survives a down/up cycle.** After `redpanda-down` then `redpanda-up`, consuming
`module-test` still yields `from the module`.

**`redpanda-status` reports accurately and exits usefully.** Non-zero when the broker is
down, zero when it is up and serving.

**`redpanda-purge` is idempotent and scoped.** Running it twice succeeds both times;
afterwards `container list --all`, `container volume list`, and `container network list`
show no `redpanda` resources; and it never touched a container without the
`dev.shinzui.redpanda.managed` label.

**The launchd plist is correct.** The generated
`Library/LaunchAgents/com.shinzui.redpanda.plist` has label `com.shinzui.redpanda`,
`RunAtLoad` true, the deliberate `KeepAlive` value, a program path in the Nix store, and
log paths under `~/.local/state/redpanda/logs`.

**The ADRs exist.** `docs/adr/` contains the no-CLI decision and the naming/port contract,
each with the rationale — and for the first, the reversal criteria.

**Failure output is actionable.** Deliberately break something and check the message. For
example, stop the Apple Container service and run `redpanda-up`:

```bash
$ container system stop
$ ./result/bin/redpanda-up
Apple Container is installed but its service is not responding.

Start it with:

    container system start
```

A bare `exit status 1` is not acceptable; section 22 of `docs/initial-spec.md` makes the
same point and it applies here.


## Idempotence and Recovery

`nix build` and `nix flake check` are pure and repeatable.

`redpanda-up` is idempotent by construction: every create is conditional on absence and
every start is conditional on state. If it fails partway — say the broker starts but
Console fails — running it again should complete the job rather than erroring on the
already-running broker. **Test this specific case explicitly**, because it is the one the
launchd agent will hit in practice after a failed login-time start.

`redpanda-down` is idempotent: stopping a stopped or missing container is a no-op.

`redpanda-purge` is idempotent and is the recovery tool for a wedged cluster: it tolerates
every resource being absent, so a purge interrupted halfway is finished by running it
again. It is also the only destructive command here — it deletes the broker's data volume,
and there is no undo. That is why it prompts. The `--force` flag exists for scripted use;
do not add it to any `just` recipe or agent.

If the cluster is wedged in a way `redpanda-down` cannot fix — containers that will not
stop, DNS that stopped resolving after the machine slept — restart Apple Container itself:

```bash
container system stop
container system start
redpanda-up
```

Record any occurrence in Surprises & Discoveries. The sleep/wake DNS failure is reported by
the community and if it happens here, the module should probably defend against it.

Nothing in this plan modifies `/Users/shinzui/Keikaku/dotfiles.nix` or the system
configuration. The blast radius is this repository plus whatever containers you start by
hand. To reset completely: `redpanda-purge --force`, then `git checkout` whatever you do
not want to keep.


## Interfaces and Dependencies

**Consumed from plan 1**
(`docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md`):

- Apple Container 1.2.2 or later, on `PATH`, with its API server running. Referenced here
  through the `package` option, never as a hard-coded `pkgs.container`.

**Consumed from plan 2**
(`docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md`):

- `docs/spikes/1-apple-container-redpanda-findings.md`, in full.

**Produced by this plan, consumed by plan 4**
(`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`):

- The flake at the repository root, exporting `homeManagerModules.default`.
- The option schema `services.redpanda-container.*` — MasterPlan Integration Point 5. Plan
  4 sets these options. Do not rename an option after plan 4 begins without changing plan 4
  in the same commit.
- The five commands: `redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
  `redpanda-purge`.
- The launchd label `com.shinzui.redpanda` and the log paths under
  `~/.local/state/redpanda/logs`, which plan 4 may reference from `just` recipes, from
  `docs/local-services.md`, and possibly from a VictoriaLogs shipper entry.
- `docs/adr/` and its first two records.

**Files created by this plan:**

```text
/Users/shinzui/Keikaku/bokuno/redpanda-container/flake.nix
/Users/shinzui/Keikaku/bokuno/redpanda-container/flake.lock
/Users/shinzui/Keikaku/bokuno/redpanda-container/modules/home/redpanda-container.nix
/Users/shinzui/Keikaku/bokuno/redpanda-container/README.md
/Users/shinzui/Keikaku/bokuno/redpanda-container/docs/adr/1-no-compiled-cli-for-local-redpanda.md
/Users/shinzui/Keikaku/bokuno/redpanda-container/docs/adr/2-redpanda-container-naming-and-port-contract.md
```

**Nix functions used:**

- `lib.mkEnableOption`, `lib.mkOption`, `lib.mkPackageOption`, `lib.mkIf`, `lib.types.*` —
  module option declaration.
- `pkgs.writeShellApplication` — generates a linted script with `set -euo pipefail` and a
  `runtimeInputs` `PATH`.
- `pkgs.symlinkJoin` or `pkgs.buildEnv` — bundle the five scripts into one testable package.
- `lib.hm.dag.entryAfter` / `lib.hm.dag.entryBefore` — order `home-manager` activation
  scripts. Worked examples: `home.activation.victorialogs-init` and
  `home.activation.victorialogs-stop-agents` in
  `/Users/shinzui/Keikaku/dotfiles.nix/home/victorialogs.nix`.
- `launchd.agents.<name>` from `home-manager` — declares the macOS launch agent.

**Runtime dependencies of the generated scripts** (all via `runtimeInputs`):

- the Apple Container package (`container`)
- `jq` — parse `container list --format json` and `container inspect`
- `curl` — readiness polling and service probes
- `coreutils` — `sleep`, `mkdir`, `printf`

Note that `rpk` is deliberately **not** a runtime dependency. The scripts manage
containers; they do not talk the Kafka protocol. Generating the `rpk` profile is plan 4's
concern, which keeps this module usable by someone who does not have `rpk` installed.
