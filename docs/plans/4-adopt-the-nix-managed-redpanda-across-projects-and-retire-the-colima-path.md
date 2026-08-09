---
id: 4
slug: adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path
title: "Adopt the Nix-managed Redpanda across projects and retire the colima path"
kind: exec-plan
created_at: 2026-08-09T00:15:03Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
master_plan: "docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md"
---


# Adopt the Nix-managed Redpanda across projects and retire the colima path

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Plan 3 built a `home-manager` module that runs Redpanda on Apple Container, and proved it
works by running its scripts by hand. This plan makes the machine actually use it: wires
the module into the system configuration, generates an `rpk` profile so every project
reaches the cluster with no per-project setup, proves it from real project directories,
and writes down how to operate it and how to go back.

The user-visible outcome is that after a reboot, with Colima never started, this works from
any directory:

```bash
$ cd ~/Keikaku/bokuno/mori-project
$ rpk cluster info
CLUSTER
=======
redpanda.<id>

BROKERS
=======
ID    HOST        PORT
0*    127.0.0.1   9092

$ rpk topic create adoption-check
$ echo hello | rpk topic produce adoption-check
$ rpk topic consume adoption-check -n 1
{"topic":"adoption-check","value":"hello",...}

$ cd /tmp && rpk topic list
NAME             PARTITIONS  REPLICAS
adoption-check   1           1
```

Note the absence of `--brokers` — that is the whole point of the `rpk` profile. And note
that the second block runs from `/tmp`, a directory with no project configuration at all.

This is the last child plan of the MasterPlan at
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`. It is the only one
that changes the running system configuration, so it is the only one where a mistake
affects the machine's day-to-day usability. That shapes its ordering and its rollback
section.

The plan's title says "retire the colima path" and it is worth being precise about what
that means: it means **stopping depending on Colima for Redpanda**. Colima, Docker, and the
Homebrew `redpanda` formula all stay installed. The MasterPlan's Decision Log records why.


## Progress

- [x] Capture the current state as a rollback baseline (rpk profile, running services, ports) (2026-08-09)
- [x] Add the redpanda-container flake input to the dotfiles flake (2026-08-09) — GitHub URL, not a path input; the repository was already pushed
- [x] Register the module in `flake-modules/modules.nix` and create `home/redpanda.nix` (2026-08-09)
- [x] Run `darwin-rebuild switch` and confirm it succeeds with no regressions (2026-08-09) — 27 agents before, 28 after, none lost
- [x] Verify the launchd agent registered and the cluster came up (2026-08-09)
- [x] Generate and verify the `rpk` profile; delete the stale `rpk-container` one (2026-08-09)
- [x] Prove produce/consume from two unrelated project directories and from `/tmp` (2026-08-09)
- [x] Verify Console and add the Caddy `redpanda.localhost` entry (2026-08-09)
- [x] Add `just` recipes following the repository's existing conventions (2026-08-09)
- [x] Decide on VictoriaLogs shipping (2026-08-09) — decided against; see Decision Log
- [x] Update `docs/local-services.md` in the dotfiles repository (2026-08-09) — plus a correction to a pre-existing error about the Caddy proxy
- [x] Write the runbook and the rollback procedure (`docs/redpanda.md`) (2026-08-09)
- [ ] Reboot and verify the whole thing comes up with Colima never started (blocked — needs a reboot; also completes EP-1's outstanding reboot item)
- [ ] Perform the MasterPlan's ADR distillation pass (deferred to EP-5, which is now the last child plan; see Decision Log)
- [x] Record findings, decisions, and the retrospective in this plan (2026-08-09)


## Surprises & Discoveries

**`docs/local-services.md` described the Caddy proxy incorrectly, in a way that would have
misled anyone who tried to act on it.** The document said the proxy is a system launchd
daemon defined in `darwin/local-web-proxy.nix`, and its operating section gave
`sudo launchctl print system/shinzui.local-web-proxy` as the way to inspect it. None of that
is true: there is no `darwin/local-web-proxy.nix`, the file is `home/local-web-proxy.nix`,
it is declared through `launchd.agents`, and it runs as the ordinary user agent
`com.shinzui.local-web-proxy`:

```text
$ ls darwin/ | grep -i proxy      # nothing
$ grep -n "launchd" home/local-web-proxy.nix
74:  launchd.agents.local-web-proxy = {
$ launchctl list | grep local-web-proxy
25170	0	com.shinzui.local-web-proxy
```

The file's own comments explain why it is an agent — macOS does not reserve ports below
1024, so an unprivileged process binds `:80` fine, and staying in the user domain means
`launchctl kickstart` needs no `sudo`. The documented command would simply have failed.
Corrected in the same commit, since this plan was editing that document anyway. The
document's intro claim that "the web proxy is a system launchd daemon" was corrected too.

**The launchd agent ran during activation, not just at login.** `home-manager` bootstraps a
newly registered agent immediately, and `RunAtLoad = true` means it fires at that moment. So
the cluster was already up before any manual `redpanda-up`, and the agent's log shows the
idempotent path working exactly as designed:

```text
$ tail ~/.local/state/redpanda/logs/redpanda-up.stdout.log
Broker redpanda-0 already running.
Console redpanda-console already running.

Redpanda is ready.
```

`stderr` was empty. This is a useful accident: it exercised the "already running" branch
under launchd rather than under an interactive shell, which is where it actually has to work.

**`rpk` already worked flagless before any change, which made the profile decision less
obvious than it looks.** The leftover `rpk-container` profile from the Colima setup pointed
at exactly the addresses this cluster serves, so `rpk cluster info` from `/tmp` succeeded
before this plan touched anything. The reason to act was not that it was broken but that its
description had become false and that nothing declarative would recreate it on a fresh
machine.

**No `sudo` step was needed anywhere in the adoption**, which is the payoff from EP-2 having
tested the DNS path and found it useless. The plan's Interfaces section had flagged the
`sudo container system dns create` requirement as something that might have to become a
manual runbook step or a `nix-darwin` system activation script. It did not, because the
spike established the step does not help. The only `sudo` in this whole plan is
`darwin-rebuild switch` itself.


## Decision Log

- Decision: Keep Colima, Docker, `lazydocker`, the `DOCKER_HOST` environment variable, and
  the Homebrew `redpanda` formula installed.
  Rationale: the goal is to stop *needing* Colima for Redpanda, not to remove it. `rpk`
  itself comes from the Homebrew formula and is what reads the profile this plan generates.
  Other tooling may still use the Docker socket. Colima is the fallback if Apple Container
  proves unreliable. Removing any of them is a separate decision to make after this has run
  for a while, and it should be its own plan.
  Date: 2026-08-08

- Decision: Replace the existing `rpk-container` profile rather than adding a new one
  alongside it.
  Rationale: `~/Library/Application Support/rpk/rpk.yaml` already contains a profile named
  `rpk-container`, generated by a previous `rpk container start`, pointing at
  `127.0.0.1:9092` / `9644` / `8081` — exactly the addresses this cluster serves. Two
  profiles pointing at the same addresses is a trap: `rpk profile use` would silently
  determine which one is "current" and they would drift. Decide during implementation
  whether to rename the managed profile to something clearer (`local`, `apple`) and delete
  the old one; record the choice.
  Date: 2026-08-08

- Decision: Do this after plan 3 rather than in parallel with it.
  Rationale: this plan runs `darwin-rebuild switch`, which affects the whole machine. Doing
  it only once the module has been exercised standalone means a module bug shows up as a
  failed `nix build` in a scratch directory rather than a broken system generation.
  Date: 2026-08-08

- Decision: Register the module in `flake-modules/modules.nix` rather than importing it from
  `home/redpanda.nix`.
  Rationale: the plan offered two routes and asked which fits the repository's grain.
  `flake-modules/darwin-configurations.nix` already imports
  `lib.attrValues self.homeManagerModules` into the `home-manager` configuration, and
  `modules.nix` exists precisely to declare "reusable modules exported by this flake", so a
  foreign flake's module belongs there. The alternative — importing it inside
  `home/redpanda.nix` — would have required extending `home-manager.extraSpecialArgs`, which
  currently passes only `age`, to thread `inputs` into every `home/*.nix` file. That is a
  wider change to support one import. The split also reads well: `modules.nix` declares the
  module, `home/redpanda.nix` configures it.
  Date: 2026-08-09

- Decision: Use the GitHub URL `github:shinzui/redpanda-container` as the flake input, not a
  local path input.
  Rationale: the plan allowed a path input during development but asked that it be switched
  before finishing. The repository was already pushed and `nix flake metadata` resolved it,
  so there was no development phase needing the path form. A path input would pin to the
  working tree rather than a commit and make the dotfiles flake non-portable.
  Date: 2026-08-09

- Decision: Option 2 for the `rpk` profile — create it imperatively from a `home.activation`
  hook, only when absent — and delete the leftover `rpk-container` profile.
  Rationale: option 3 (declaring the file with `home.file`) was rejected because `rpk` owns
  `~/Library/Application Support/rpk/rpk.yaml` and rewrites it on every `rpk profile`
  command, so declaring it would silently revert any profile added by hand on the next
  rebuild, and `home-manager` would have renamed the existing file to `rpk.yaml.backup` on
  first activation. Letting `rpk` write its own file also keeps `rpk` the authority on a
  schema that carries a `version:` field a future release could bump. Option 1 (leave the
  old profile alone) was tempting because it already worked, but its description —
  "Automatically generated profile from 'rpk container start'" — had become false, and
  nothing declarative would recreate it on a fresh machine. The old profile was deleted
  rather than left alongside the new one because two profiles pointing at identical
  addresses is exactly the drift trap this plan's earlier Decision Log entry warned about.
  The hook creates but never overwrites, so a hand-edited profile survives.
  Date: 2026-08-09

- Decision: Add the Caddy entry for `http://redpanda.localhost`.
  Rationale: the other five local web UIs all have one, it costs three lines, and Console's
  port (8080) is the most collision-prone and least memorable of the set. Verified working
  through both the direct port and the proxy.
  Date: 2026-08-09

- Decision: Do **not** ship Redpanda's logs to VictoriaLogs.
  Rationale: the plan asked for this to be decided either way. The `shippers` list in
  `home/victorialogs.nix` tails files, and the only file Redpanda produces on the host is the
  launchd agent's `StandardOutPath` — which contains what `redpanda-up` printed at login, a
  handful of lines per boot, not Redpanda's own logs. Those live inside the container and are
  read with `container logs`. Shipping the agent's output would add two shipper agents and
  ongoing noise in exchange for almost no signal. Shipping Redpanda's actual logs would need
  a `container logs --follow` shipper, which is a different mechanism from every existing
  shipper and deserves its own plan rather than being smuggled in here. `just logs-redpanda`
  covers the interactive case.
  Date: 2026-08-09

- Decision: Move the MasterPlan's ADR distillation pass from this plan to EP-5.
  Rationale: this plan was written as the last child plan and its Milestone 5 accordingly
  closes out the MasterPlan. EP-5
  (`docs/plans/5-document-how-projects-use-the-shared-redpanda-for-testing.md`) was added
  after this plan was authored and hard-depends on it, so it is now last. Distilling before
  EP-5 runs would mean doing it again afterwards, and EP-5 owns one of the outstanding ADR
  candidates (the topic namespacing convention and the destructive-command prohibition).
  Date: 2026-08-09


## Outcomes & Retrospective

**What was achieved.** The machine now runs Redpanda on Apple Container as an ordinary local
service. `darwin-rebuild switch` succeeded and the activated system is exactly the built
configuration — `/run/current-system` and the build output resolve to the same store path.
All five commands are installed from the Nix profile, and no existing service regressed:
27 `com.shinzui.*` agents before, 28 after, none lost.

The `rpk` profile does what it exists to do. Producing in one project and consuming in a
completely unrelated directory, with no `--brokers` anywhere:

```text
$ cd ~/Keikaku/bokuno/mori-project && echo "from mori-project" | rpk topic produce adoption-check
Produced to partition 0 at offset 0 with timestamp 1786246295670.
$ cd /tmp && rpk topic consume adoption-check -n 1
{"value":"from mori-project","offset":0}
$ cd ~/Keikaku/bokuno/kafka-effectful && rpk topic list
NAME            PARTITIONS  REPLICAS
adoption-check  1           1
```

Console works through both the direct port and the proxy (`HTTP 200` from
`http://redpanda.localhost`) and lists `adoption-check`. `rpk cluster health`, the Schema
Registry, and the HTTP Proxy all respond flagless. `just status-redpanda` exits 0. Colima
reports not running throughout.

Documentation landed in the dotfiles repository: `docs/redpanda.md` as the runbook with the
rollback procedure, and `docs/local-services.md` updated — including a correction to a
pre-existing error that would have sent a reader to a nonexistent file and a command that
could not work.

**What remains.** One item, blocked rather than unresolved: the reboot test. It is the
acceptance that proves the machine works this way every day rather than once after a manual
switch, and it also closes EP-1's outstanding reboot item and re-proves volume persistence
across a full host restart, which nothing else has tested. Everything needed for it is in
place; it just needs a reboot.

The ADR distillation pass moved to EP-5, which is now the last child plan.

**Lessons worth carrying forward.** Batching every change into a single switch was worth the
discipline. The plan's steps invite three separate `darwin-rebuild switch` runs — one for the
module, one for the Caddy entry, one after the recipes — and each one needs interactive
`sudo`. Building with `./bin/build.sh` after every edit and switching once at the end caught
the same errors at no risk, because a build failure and an activation failure are the same
failure discovered in a cheaper place.

Reading the artifact rather than the documentation paid off again, this time in the other
direction: `docs/local-services.md` was the thing that was wrong, and only checking it
against `home/local-web-proxy.nix` and `launchctl list` revealed it. Documentation drifts
from configuration in exactly the places nobody has needed to act on recently.

Finally, the value of EP-2 showed up as an absence. The plan had budgeted for a `sudo
container system dns create` step possibly needing to become a manual runbook item or a
`nix-darwin` system activation script. Because the spike had already established that step
does nothing, that entire branch of work never happened.


## Context and Orientation

### The two repositories

Most of this plan's work happens in `/Users/shinzui/Keikaku/dotfiles.nix`, the Nix flake
that configures this Mac. A little happens in
`/Users/shinzui/Keikaku/bokuno/redpanda-container`, the repository this plan file lives in,
which plan 3 turned into a flake exporting a `home-manager` module.

### How the dotfiles flake is structured

`/Users/shinzui/Keikaku/dotfiles.nix/flake.nix` is a `flake-parts` flake. Its `inputs` set
lists around thirty inputs. The pattern for this user's own tools is consistent — each is a
GitHub flake whose nixpkgs is pinned to a shared Haskell toolchain flake:

```nix
    mori = {
      url = "github:shinzui/mori";
      inputs.nixpkgs.follows = "haskell-nix-dev/nixpkgs";
      inputs.haskell-nix-dev.follows = "haskell-nix-dev";
    };
```

`redpanda-container` is **not** a Haskell project — it is a Nix module — so it should
follow `nixpkgs-unstable` instead:

```nix
    redpanda-container = {
      url = "github:shinzui/redpanda-container";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
```

Check whether that input name exists on GitHub. The repository was created as
`shinzui/redpanda-container` (private) per `.seihou/manifest.json`, so the URL above should
resolve, but the flake needs to have been pushed. During development you may prefer a local
path input (`url = "path:/Users/shinzui/Keikaku/bokuno/redpanda-container"`) — that works
but makes the flake non-portable and pins to your working tree rather than a commit.
Decide, and if you use a path input during development, switch to the GitHub URL before
finishing.

`flake.nix` imports four modules from `flake-modules/`:

- `overlays.nix` — `flake.overlays`, including `my-packages` where plan 1 registered the
  `container` attribute.
- `packages.nix` — per-system buildable packages.
- `darwin-configurations.nix` — assembles the system configuration named `SungkyungM1X`.
  Its `homeManagerCommonConfig` imports `lib.attrValues self.homeManagerModules` plus the
  `../home` directory.
- `modules.nix` — `flake.homeManagerModules`, currently four small config modules.

`home/default.nix` is `home-manager`'s entry point. It has an `imports` list pulling in the
other `home/*.nix` files and a long `home.packages` list.

### Launchd and local-service conventions

Documented at `/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`, which this plan
must update. Read it in full before starting; the parts that matter:

- Per-user launchd agents labelled `com.shinzui.<name>`, all starting at login.
- A Caddy system daemon on port 80 provides friendly `*.localhost` URLs mapping to loopback
  ports — `http://logs.localhost` to 9428, `http://mina.localhost` to 8765, and so on.
  It is defined in `darwin/local-web-proxy.nix`. Redpanda Console on 8080 is an obvious
  candidate for `http://redpanda.localhost`.
- VictoriaLogs (`home/victorialogs.nix`) ships per-service stdout/stderr log files into a
  searchable store. The `shippers` list there is the single source of truth; adding an entry
  is two lines. Whether Redpanda's logs belong there is a decision this plan makes.
- `just` recipes follow the families `status-*`, `restart-*`, `logs-*`. See the `Justfile`
  at the dotfiles repository root.

Ports currently in use per that document — VictoriaLogs 9428, VictoriaTraces 10428, Jaeger
16686, mina 8765, reiko 8770, rei kiroku metrics 9091, Caddy 80 — none collide with this
cluster's 9092 / 9644 / 8081 / 8082 / 8080. Verify anyway at implementation time; the
document can lag.

### How `rpk` finds its configuration

`rpk` is Redpanda's command-line tool, installed here from Homebrew at
`/opt/homebrew/bin/rpk`, currently v26.2.1. It reads a configuration file whose default
search path on macOS is `~/Library/Application Support/rpk/rpk.yaml` — **not**
`~/.config/rpk/`, which does not exist on this machine and is a common wrong guess.

That file holds *profiles*. A profile is a named set of cluster addresses; `rpk` uses the
one named by `current_profile` unless overridden by the `RPK_PROFILE` environment variable
or the `--profile` flag. The current contents:

```yaml
version: 7
globals:
    prompt: ""
    ...
current_profile: rpk-container
current_cloud_auth_org_id: ""
current_cloud_auth_kind: ""
profiles:
    - name: rpk-container
      description: Automatically generated profile from 'rpk container start'
      prompt: ""
      from_cloud: false
      kafka_api:
        brokers:
            - 127.0.0.1:9092
      admin_api:
        addresses:
            - 127.0.0.1:9644
      schema_registry:
        addresses:
            - 127.0.0.1:8081
cloud_auth: []
```

This is a leftover from the Colima-based `rpk container start`. Its addresses happen to be
exactly the ones this cluster serves, which is convenient and also a trap — see the
Decision Log.

The profile can be created imperatively:

```bash
rpk profile create local \
  --description "Local Redpanda on Apple Container" \
  --set kafka_api.brokers=127.0.0.1:9092 \
  --set admin_api.addresses=127.0.0.1:9644 \
  --set schema_registry.addresses=127.0.0.1:8081
```

`rpk profile create` always switches to the new profile. Note the file's `version: 7` field
— if you write the YAML declaratively instead of using `rpk profile create`, you must
reproduce the schema `rpk` expects, and a version bump in a future `rpk` would silently
break it. That tension is what the "how to manage the profile" decision below is about.

### The decision this plan must make about the profile

Three options, to be decided during implementation and recorded:

1. **Leave it alone.** The existing `rpk-container` profile already points at the right
   addresses. Zero work, zero risk, but nothing about it is declarative and its description
   ("Automatically generated profile from 'rpk container start'") becomes a lie.
2. **Generate it imperatively from a `home.activation` hook.** Run `rpk profile create` (or
   `rpk profile set`) at activation time if the profile is absent or wrong. Keeps `rpk` as
   the authority on its own file format. Needs care to be idempotent and to not clobber
   profiles the user created by hand.
3. **Write the file declaratively with `home.file`.** Fully declarative, but takes ownership
   of a file `rpk` also writes, meaning any `rpk profile` command the user runs gets
   reverted on the next rebuild — and `home-manager` would move the existing file to
   `rpk.yaml.backup` on first activation (the configuration sets
   `home-manager.backupFileExtension = "backup"`).

Option 2 is the recommended starting point: it is declarative in intent, does not fight
`rpk` over file ownership, and matches how `home/postgresql.nix` handles database creation
(a `pg-ensure-db` script rather than a declaratively-written data directory). But weigh it
against option 1, which may genuinely be enough. Record the choice and the reasoning.

### What plan 3 produced that this plan consumes

- A flake at `/Users/shinzui/Keikaku/bokuno/redpanda-container` exporting
  `homeManagerModules.default`.
- The option schema `services.redpanda-container.*` — `enable`, `package`, `redpandaImage`,
  `consoleImage`, `enableConsole`, `network`, `brokerName`, `consoleName`, `volumeName`,
  `internalHost`, `dnsDomain`, `ports.*`, `hostAddress`, `cpus`, `memory`, `stateDir`,
  `autoStart`, `readyTimeoutSeconds`. Read the module source for the authoritative list and
  defaults; this plan's copy may have drifted.
- Five commands: `redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
  `redpanda-purge`.
- The launchd label `com.shinzui.redpanda` and log paths under
  `~/.local/state/redpanda/logs/`.
- `docs/adr/` with the first two records.

### What plan 2's findings might require of this plan

Read `docs/spikes/1-apple-container-redpanda-findings.md`. One finding in particular can
land here: **if container-to-container name resolution requires
`sudo container system dns create <domain>`, that step needs administrator privileges and
therefore cannot run from a `home-manager` activation hook without a password prompt.** It
would have to be either a one-time manual step documented in the runbook, or a
`nix-darwin` system activation script (which does run as root). Check the findings and
handle it deliberately rather than discovering it when Console cannot reach the broker.

### ADR context

Plan 3 created `/Users/shinzui/Keikaku/bokuno/redpanda-container/docs/adr/` with two
records:

- `docs/adr/1-no-compiled-cli-for-local-redpanda.md` — why this is a Nix module rather than
  the compiled tool `docs/initial-spec.md` proposes, and the criteria that would justify
  building one.
- `docs/adr/2-redpanda-container-naming-and-port-contract.md` — the resource names, labels,
  and host ports.

Read both; this plan must not contradict them, and if adoption forces a change to the
naming or port contract, ADR 2 must be updated in the same commit.

`/Users/shinzui/Keikaku/dotfiles.nix` has no `docs/adr/` and no `mori.dhall`. Its durable
conventions live in `docs/local-services.md`, which this plan updates rather than
converting to ADRs — converting that repository to an ADR corpus is separate work and
should not happen as a side effect here. A Mori registry search found no relevant
cross-repository decisions:

```bash
$ mori registry concepts --search 'container runtime' --json
[]
```

This plan is also where the MasterPlan's ADR distillation pass happens, since it is the last
child plan. See Milestone 5.


## Plan of Work

Five milestones, ordered so the riskiest step happens once everything cheap has been
verified.

### Milestone 1 — Baseline and rollback preparation

Before changing anything, capture enough state to undo it. This is short and it is what
makes the rest safe.

Record the current `darwin-rebuild` generation number, the contents of
`~/Library/Application Support/rpk/rpk.yaml`, which launchd agents are loaded, what is
listening on the five target ports, and whether Colima is running. Copy the `rpk.yaml`
somewhere outside the repository. Commit nothing yet.

Also confirm plans 1 through 3 are actually complete: `container --version` reports 1.2.2 or
later, the spike findings document exists, and plan 3's flake builds.

### Milestone 2 — Wire the module in

At the end of this milestone `darwin-rebuild switch` has succeeded with the module active,
and `redpanda-status` works from a fresh shell.

Add the flake input to `/Users/shinzui/Keikaku/dotfiles.nix/flake.nix`. Create
`/Users/shinzui/Keikaku/dotfiles.nix/home/redpanda.nix` — a small file that imports the
module and sets `services.redpanda-container.enable = true` plus any options that differ
from the module's defaults. Add it to the `imports` list in
`/Users/shinzui/Keikaku/dotfiles.nix/home/default.nix`.

There is a wrinkle about *how* the module gets imported. The `home-manager` configuration in
`flake-modules/darwin-configurations.nix` imports `lib.attrValues self.homeManagerModules`
and the `../home` directory. A foreign flake's module is not in either. Two workable routes:
have `home/redpanda.nix` itself contain
`imports = [ inputs.redpanda-container.homeManagerModules.default ];`, which requires
`inputs` to be in scope in that file (check how other `home/*.nix` files access flake
inputs — `home/mori.nix` uses `pkgs.mori`, which comes via the overlay, not via `inputs`,
so this may need `home-manager.extraSpecialArgs` to be extended in
`flake-modules/darwin-configurations.nix`); or add the module to `flake.homeManagerModules`
in `flake-modules/modules.nix`, which is already wired into the configuration. Work out
which fits the repository's grain and record it.

Then run `darwin-rebuild switch` and verify.

### Milestone 3 — The `rpk` profile and cross-project proof

At the end of this milestone `rpk` works with no flags from any directory.

Make the profile decision described in Context and Orientation, implement it, and then
prove it from at least three places: two real project directories that are unrelated to
each other, and `/tmp`. Using `/tmp` matters — it proves nothing project-local is involved.
Good candidates for the real projects are directories under `~/Keikaku/bokuno/`; pick two
that a future reader would recognise as genuinely separate.

The proof is producing in one directory and consuming in another. That demonstrates a
single shared cluster rather than two coincidentally-working setups, which is the actual
requirement.

### Milestone 4 — Operations: Console, recipes, logs, and the reboot test

At the end of this milestone the cluster is a first-class local service like the others.

Verify Console at `http://127.0.0.1:8080` and decide whether to add a Caddy entry for
`http://redpanda.localhost` in `darwin/local-web-proxy.nix`. The other five services have
one; consistency argues for it, and it costs three lines.

Add `just` recipes following the existing families: `status-redpanda`, `restart-redpanda`,
`logs-redpanda`. Look at how `status-postgres` and `restart-mori` are implemented and
match them. Do **not** add a recipe wrapping `redpanda-purge` — it destroys data and a
one-word `just` recipe is too easy to run by accident.

Decide about VictoriaLogs shipping. The `shippers` list in `home/victorialogs.nix` covers
seven services and takes two entries per service (stdout and stderr). Redpanda's *container*
logs come from `container logs`, not a file, so what would ship is the launchd agent's
`StandardOutPath`/`StandardErrorPath` — the output of `redpanda-up`, not Redpanda's own
logs. That is much less useful than it first sounds. Decide whether it is worth it and
record the reasoning either way; if Redpanda's own logs are wanted in VictoriaLogs, that is
a larger piece of work (a `container logs --follow` shipper) and should be a follow-up plan
rather than scope creep here.

Then the real test: reboot, log in, and verify the cluster came up with no manual step and
with Colima never started.

### Milestone 5 — Documentation, distillation, and closing the MasterPlan

At the end of this milestone the initiative is finished and a future reader can operate and
undo it.

Update `/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`: add Redpanda to the
service tables, to the friendly-URL table if you added the Caddy entry, and to the
operating section with its `just` recipes. Match the document's existing voice.

Write the runbook. It belongs in the dotfiles repository next to the other operational docs
— something like `docs/redpanda.md`, alongside the existing `docs/mori.md` and
`docs/rei.md`. It must cover: what runs and where, the five commands, how to check health,
the common failure modes and their fixes (Apple Container service not running, DNS broken
after sleep/wake, port already in use, cluster wedged), how to reach Console, and where the
data lives and how to destroy it.

Write the rollback procedure — see Idempotence and Recovery below for its content; the
runbook should carry it too, because the day you need it is not the day you want to be
reading an ExecPlan.

Finally, perform the MasterPlan's ADR distillation pass. Read the Decision Log, Surprises &
Discoveries, and Outcomes & Retrospective of the MasterPlan and all four child plans, and
promote anything durable into `/Users/shinzui/Keikaku/bokuno/redpanda-container/docs/adr/`
— updating ADRs 1 and 2 where the work changed them, and adding a third if something
durable emerged that neither covers. Leave task-local execution detail in the plans. Then
mark every plan Complete in the MasterPlan's Exec-Plan Registry and fill in its Outcomes &
Retrospective.


## Concrete Steps

### Step 1 — baseline

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
darwin-rebuild --list-generations | tail -5
cp ~/Library/Application\ Support/rpk/rpk.yaml /tmp/rpk.yaml.before-adoption
launchctl list | grep com.shinzui | sort
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9092|9644|8081|8082|8080)\b'
colima status
container --version
container system status
ls -la /Users/shinzui/Keikaku/bokuno/redpanda-container/docs/spikes/
```

Write the generation number down. The `lsof` output should be empty; if it is not, find out
what holds the port before continuing.

### Step 2 — build plan 3's flake from the dotfiles' perspective

Before adding it as an input, confirm it builds standalone:

```bash
cd /Users/shinzui/Keikaku/bokuno/redpanda-container
nix flake check
nix build .#redpanda-scripts --print-out-paths
```

If you plan to use a GitHub URL rather than a path input, push first and confirm it
resolves:

```bash
git push
nix flake metadata github:shinzui/redpanda-container
```

### Step 3 — add the input

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
$EDITOR flake.nix          # add the redpanda-container input
nix flake lock --update-input redpanda-container
git diff flake.lock | head -30
```

### Step 4 — the home module

```bash
$EDITOR home/redpanda.nix
$EDITOR home/default.nix   # add ./redpanda.nix to imports
```

A minimal `home/redpanda.nix` sets only what differs from the module's defaults. Resist
restating defaults — a file that repeats every default is noise that drifts.

Check it evaluates before switching:

```bash
nix build .#darwinConfigurations.SungkyungM1X.system --print-out-paths
```

This builds the whole system without activating it, which catches evaluation and build
errors while the running system is untouched. **Do this before Step 5**; it is the cheapest
place to find a mistake.

### Step 5 — switch

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
just --list                # check for a preferred rebuild recipe first
darwin-rebuild switch --flake .#SungkyungM1X
```

Then, in a **new** shell:

```bash
which redpanda-up redpanda-status
launchctl print gui/$(id -u)/com.shinzui.redpanda | head -20
redpanda-status
```

If the agent ran at activation, the cluster may already be up. If not:

```bash
redpanda-up
```

Confirm nothing else regressed:

```bash
launchctl list | grep com.shinzui | sort
```

Compare against the baseline from Step 1. Every agent that was loaded before should still
be loaded.

### Step 6 — the rpk profile

Implement whichever option you chose. If option 2 (imperative, from an activation hook),
the manual equivalent to test first is:

```bash
rpk profile create local \
  --description "Local Redpanda on Apple Container (managed by home/redpanda.nix)" \
  --set kafka_api.brokers=127.0.0.1:9092 \
  --set admin_api.addresses=127.0.0.1:9644 \
  --set schema_registry.addresses=127.0.0.1:8081

rpk profile list
rpk profile print
```

Then decide the fate of the old `rpk-container` profile:

```bash
rpk profile delete rpk-container
rpk profile list
```

### Step 7 — cross-project proof

```bash
cd ~/Keikaku/bokuno/mori-project && rpk cluster info
cd ~/Keikaku/bokuno/mori-project && rpk topic create adoption-check
cd ~/Keikaku/bokuno/mori-project && echo "from mori-project" | rpk topic produce adoption-check

cd /tmp && rpk topic list
cd /tmp && rpk topic consume adoption-check -n 1
```

Expected: the last command prints a record whose `value` is `from mori-project`, produced
from a completely different directory. Repeat with a second real project directory.

Also verify the other services with no flags:

```bash
rpk cluster health
curl -s http://127.0.0.1:8081/subjects
curl -s http://127.0.0.1:8082/topics
```

### Step 8 — Console and the friendly URL

```bash
curl -sf http://127.0.0.1:8080 -o /dev/null -w '%{http_code}\n'
open http://127.0.0.1:8080
```

Expected: 200, and the browser shows the broker and `adoption-check`.

If adding the Caddy entry:

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
$EDITOR darwin/local-web-proxy.nix
darwin-rebuild switch --flake .#SungkyungM1X
curl -sf http://redpanda.localhost -o /dev/null -w '%{http_code}\n'
```

### Step 9 — just recipes

```bash
$EDITOR Justfile
just --list | grep redpanda
just status-redpanda
just logs-redpanda
```

### Step 10 — the reboot test

This is the acceptance that matters most, because it is the one that proves the machine
works this way every day rather than once after a manual switch.

```bash
colima stop || true
sudo reboot
```

After logging back in, **without running any command first**:

```bash
container system status
redpanda-status
colima status
cd /tmp && rpk topic consume adoption-check -n 1
```

Expected: the API server is running, the cluster is up, Colima is not running, and the
message produced before the reboot is still there. That last point also re-proves volume
persistence across a full host restart, which no earlier plan tested.

### Step 11 — documentation

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
$EDITOR docs/local-services.md
$EDITOR docs/redpanda.md
git add -A
git commit -m "feat: run local Redpanda on Apple Container

Add the redpanda-container flake input and home/redpanda.nix, wiring in
the home-manager module that runs a Redpanda broker and Console on Apple
Container. Adds just recipes and the operations runbook. Colima is no
longer needed for local Redpanda.

MasterPlan: docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
ExecPlan: docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md
Intention: intention_01kzhxfhpqekma79h936t7t2pk"
```

Note that the `MasterPlan:` and `ExecPlan:` trailer paths refer to files in the
`redpanda-container` repository, not this one. That is intentional and correct — the
trailers identify the plan the work was done under, wherever it lives.

### Step 12 — distillation and closing out

```bash
cd /Users/shinzui/Keikaku/bokuno/redpanda-container
$PAGER docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
$PAGER docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md
$PAGER docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md
$PAGER docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md
$EDITOR docs/adr/     # update ADRs 1 and 2; add a third if warranted
$EDITOR docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
```

Mark all four plans Complete in the Exec-Plan Registry, check off the Progress items, and
fill in the MasterPlan's Outcomes & Retrospective.


## Validation and Acceptance

The initiative is complete when all of the following hold on a freshly rebooted machine on
which Colima has not been started.

**The system builds and switches cleanly.**

```bash
$ cd /Users/shinzui/Keikaku/dotfiles.nix
$ darwin-rebuild switch --flake .#SungkyungM1X
```

completes with no error, and every launchd agent that was loaded beforehand is still
loaded.

**The cluster starts at login with no manual step.** After a reboot, in the first shell you
open:

```bash
$ redpanda-status
NAME               ROLE     STATE    ADDRESS
redpanda-0         broker   running  127.0.0.1:9092
redpanda-console   console  running  http://127.0.0.1:8080
$ echo $?
0
```

**Colima is not running.**

```bash
$ colima status
# reports not running
```

**`rpk` works with no flags from anywhere.** From two unrelated project directories and
from `/tmp`:

```bash
$ rpk cluster info
$ rpk topic list
```

both succeed without `--brokers` and without `RPK_PROFILE`.

**Produce in one directory, consume in another.**

```bash
$ cd ~/Keikaku/bokuno/mori-project && echo "from mori-project" | rpk topic produce adoption-check
$ cd /tmp && rpk topic consume adoption-check -n 1
{"topic":"adoption-check","value":"from mori-project",...}
```

**Console works and sees the cluster.** `http://127.0.0.1:8080` (and
`http://redpanda.localhost` if the Caddy entry was added) shows one broker and the
`adoption-check` topic.

**Data survived the reboot.** The `adoption-check` message produced before Step 10's reboot
is still consumable after it.

**The lifecycle commands behave.**

```bash
$ redpanda-down && redpanda-status; echo "exit=$?"   # non-zero, containers stopped
$ redpanda-up && redpanda-status; echo "exit=$?"     # zero, data intact
```

**`just` recipes exist and work.**

```bash
$ just status-redpanda
$ just logs-redpanda
$ just restart-redpanda
```

and there is deliberately no `just` recipe for purging.

**Documentation is current.** `/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md`
lists Redpanda in its service tables, and `docs/redpanda.md` contains the runbook including
the rollback procedure.

**The MasterPlan is closed out.** All four plans are Complete in the registry, Progress is
fully checked, Outcomes & Retrospective is written, and `docs/adr/` reflects the durable
decisions.


## Idempotence and Recovery

`darwin-rebuild switch` is idempotent; running it twice changes nothing the second time. If
it fails, the previous generation stays active and the machine keeps working — fix the
expression and run it again.

`nix build .#darwinConfigurations.SungkyungM1X.system` is completely safe: it builds without
activating. Use it liberally.

`rpk profile create` fails if the profile name exists; `rpk profile set` modifies the
current one. An activation hook must handle both cases, and must not clobber a profile the
user created by hand. Test the hook twice in a row.

### Rollback

Write this into `docs/redpanda.md` as well; the day you need it is not the day to be
reading an ExecPlan.

To stop the cluster without undoing anything:

```bash
redpanda-down
```

To disable it but keep everything installed, set `services.redpanda-container.enable =
false` in `/Users/shinzui/Keikaku/dotfiles.nix/home/redpanda.nix` and switch. The volume
and its data survive.

To go back to the previous system generation entirely:

```bash
darwin-rebuild --list-generations
sudo darwin-rebuild --switch-generation <N>    # the number recorded in Step 1
```

To restore the `rpk` profile as it was before adoption:

```bash
cp /tmp/rpk.yaml.before-adoption ~/Library/Application\ Support/rpk/rpk.yaml
rpk profile list
```

To return to the Colima path for Redpanda:

```bash
redpanda-down
colima start
rpk container start
```

Both stacks can technically coexist, but **not at the same time** — they bind the same host
ports. Stop one before starting the other.

To destroy the data:

```bash
redpanda-purge
```

This is the only irreversible action in the plan. It deletes the `redpanda-0-data` volume
and everything in it. It prompts for confirmation, and it is deliberately absent from the
`just` recipes.

### If things go wrong mid-plan

A failed `darwin-rebuild switch` leaves the system on its previous generation; nothing is
half-applied. A launchd agent that crash-loops shows up in
`launchctl print gui/$(id -u)/com.shinzui.redpanda` and its output is at
`~/.local/state/redpanda/logs/`; disable it by setting `autoStart = false` and switching,
rather than fighting it live. A wedged Apple Container runtime is fixed with
`container system stop && container system start` followed by `redpanda-up` — record any
occurrence, especially if it follows a sleep/wake cycle, since that failure mode is
reported upstream and may deserve defending against.


## Interfaces and Dependencies

**Consumed from plan 1**
(`docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md`):

- The `container` overlay attribute in
  `/Users/shinzui/Keikaku/dotfiles.nix/flake-modules/overlays.nix`, at 1.2.2 or later. This
  is what `services.redpanda-container.package` resolves to by default.
- Whatever mechanism starts `container system start` automatically.

**Consumed from plan 2**
(`docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md`):

- Whether a `sudo container system dns create <domain>` step is required. If so it needs
  administrator privileges, cannot run from a `home-manager` activation hook, and must
  appear in the runbook or a `nix-darwin` system activation script.

**Consumed from plan 3**
(`docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md`):

- The flake exporting `homeManagerModules.default`.
- The option schema `services.redpanda-container.*` — MasterPlan Integration Point 5.
- The commands `redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
  `redpanda-purge`.
- The launchd label `com.shinzui.redpanda` and the log directory
  `~/.local/state/redpanda/logs/`.
- `docs/adr/1-no-compiled-cli-for-local-redpanda.md` and
  `docs/adr/2-redpanda-container-naming-and-port-contract.md`.

**Files modified in `/Users/shinzui/Keikaku/dotfiles.nix`:**

```text
flake.nix                     add the redpanda-container input
flake.lock                    regenerated
home/redpanda.nix             new — imports the module, sets options
home/default.nix              add ./redpanda.nix to imports
Justfile                      add status-redpanda / restart-redpanda / logs-redpanda
docs/local-services.md        add Redpanda to the service tables
docs/redpanda.md              new — the operations runbook
darwin/local-web-proxy.nix    optional — redpanda.localhost -> 127.0.0.1:8080
flake-modules/modules.nix     possibly, depending on how the module is imported
home/victorialogs.nix         only if log shipping is adopted
```

**Files modified in `/Users/shinzui/Keikaku/bokuno/redpanda-container`:**

```text
docs/adr/*
    distillation updates to ADRs 1 and 2, plus a third if warranted

docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md
    Exec-Plan Registry statuses, Progress checkboxes, Outcomes & Retrospective

docs/plans/1-package-apple-container-at-its-latest-release-in-nix.md
docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md
docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md
docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md
    Progress and Outcomes & Retrospective sections
```

**External tools:**

- `darwin-rebuild` — `switch`, `--list-generations`, `--switch-generation`.
- `nix` — `flake check`, `flake lock`, `flake metadata`, `build`.
- `launchctl` — `list`, `print gui/$(id -u)/<label>`, `kickstart -k`.
- `rpk` v26.2.1 from `/opt/homebrew/bin/rpk` — `profile create|list|print|delete|use`,
  `cluster info|health`, `topic create|produce|consume|list`. Configuration at
  `~/Library/Application Support/rpk/rpk.yaml`, **not** `~/.config/rpk/`.
- `container` — `system status`, `list`, `logs`.
- `colima` — `status`, `stop`, `start`. Used only to prove it is not needed and to describe
  the fallback.
- `curl`, `lsof`, `just`.
