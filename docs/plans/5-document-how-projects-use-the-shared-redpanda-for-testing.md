---
id: 5
slug: document-how-projects-use-the-shared-redpanda-for-testing
title: "Document how projects use the shared Redpanda for testing"
kind: exec-plan
created_at: 2026-08-09T02:40:18Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
master_plan: "docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md"
---

# Document how projects use the shared Redpanda for testing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Earlier plans in this initiative make one shared Redpanda cluster run on this machine, at
fixed localhost ports, started automatically at login. This plan answers the question that
immediately follows: **what should every other project on this machine actually do about
it?**

Today each project that needs Kafka starts its own broker. `kafka-effectful` and
`hw-kafka-streamly` each run `rpk container start` through `process-compose`;
`hw-kafka-client` has a `docker-compose.yml` that starts a Redpanda of its own. All of them
bind host port 9092. That means each of them requires Colima to be running, only one of
them can run at a time, and any of them started while the shared cluster is up will fail to
bind its ports.

After this plan, a developer or coding agent working in any of those repositories can read
one document and know exactly what to do: how to reach the shared cluster, how to name
topics so two projects testing simultaneously do not corrupt each other's data, how to make
a test suite wait for the cluster instead of failing on a cold start, which commands are
now forbidden because they would destroy other projects' data, and how to opt out and run a
private throwaway cluster when a test genuinely needs isolation.

The deliverable is a guide in this repository at `docs/using-the-shared-cluster.md`, plus
worked migrations of the three known consumers so the guide is proven rather than
hypothetical.

The observable outcome is that two different projects' test suites can run **at the same
time** against the shared cluster without interfering, with Colima never started:

```bash
# terminal 1, in one project
cabal test

# terminal 2, in a different project, simultaneously
cabal test
```

both passing, and afterwards `rpk topic list` showing each project's topics under its own
prefix with no cross-contamination.

This is child plan 5 of the MasterPlan at
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`.


## Progress

- [x] Inventory every project on this machine that starts its own Kafka or Redpanda (2026-08-09) — **nine**, not the three this plan assumed
- [x] Decide and record the policy on destructive `rpk` commands against the shared cluster (2026-08-09)
- [x] Migrate `mori` off `rpk container start`, including removing its Colima `DOCKER_HOST` wiring (2026-08-09)
- [x] Migrate `kafka-effectful`, `kafka-effectful-jitsurei`, `hw-kafka-streamly`, `kawa`, `keiro-runtime-jitsurei`, `kizashi`, `shibuya-kafka-adapter` (2026-08-09)
- [x] Migrate `meibo`, preserving its genuine clean-state requirement by resetting only its own topic (2026-08-09)
- [x] Decide what to do about `hw-kafka-client`'s `docker-compose.yml` (2026-08-09) — documented exception, not migrated
- [x] Prove a topic reset clears one project's data and leaves other projects' topics intact (2026-08-09)
- [ ] Decide and record the topic-namespacing convention as a written rule (every migrated project already prefixes, but the rule is not yet stated anywhere a newcomer would find it)
- [ ] Write `docs/using-the-shared-cluster.md`
- [ ] Document the escape hatch for tests that need a private cluster
- [ ] Prove two projects' suites run simultaneously without interference
- [ ] Promote the namespacing convention and destructive-command prohibition to `docs/adr/`
- [ ] Perform the MasterPlan's ADR distillation pass (inherited from EP-4; this is now the last child plan)
- [ ] Record findings, decisions, and the retrospective in this plan


## Surprises & Discoveries

**The inventory found nine consumers, not three.** This plan's Context and Orientation names
`kafka-effectful`, `hw-kafka-streamly`, and `hw-kafka-client`. That list came from a search
whose `--include` globs silently failed under zsh, so it was wrong. A correct search finds
nine projects with live configuration that starts its own broker:

```text
mori-project/mori                                   process-compose.yaml + nix/haskell.nix
kafka-effectful                                     process-compose.yaml
kafka-effectful-project/kafka-effectful-jitsurei    process-compose.yaml
hw-kafka-streamly                                   process-compose.yaml
kawa                                                process-compose.yaml
keiro-runtime-jitsurei                              process-compose.yaml
kizashi                                             process-compose.yaml
meibo-project/meibo                                 process-compose.yaml
shibuya-project/shibuya-kafka-adapter               process-compose.yaml
hw-kafka-client                                     docker-compose.yml
```

Eight of the nine ran a byte-identical block — `rpk container start -n 1 --kafka-ports 9092`
with `rpk container purge` on shutdown — which made a scripted replacement safer than eight
hand edits. The lesson is narrower than "search harder": a shell glob that fails silently
produces a *confidently wrong* answer, and this plan was authored on top of one.

**One project has a genuine clean-state requirement, and it is documented in its own
config.** `meibo-project/meibo/process-compose.yaml` explained its purge:

```text
# `rpk container purge` on shutdown so a restart starts from a clean broker;
# without it a re-run replays yesterday's meibo.v1 messages.
```

This is the destructive-test case that was raised as an open question during EP-3, and the
answer is better than a per-project cluster. meibo does not need an isolated *cluster*; it
needs an empty `meibo.v1`. Deleting its own prefixed topic at startup gives exactly the same
clean slate, costs nothing, and cannot touch another project. Proven directly — a seeded
message is gone after the reset while every other project's topic survives:

```text
before reset:  {"value":"yesterdays-message"}
after reset:   _schemas, adoption-check, mori.project.v1, mori.v1     # meibo.v1 gone
```

That is strong evidence that the MasterPlan's exclusion of per-project clusters is right, and
that "this test needs a clean broker" usually means "this test needs a clean topic".

**A one-shot check breaks `depends_on: process_healthy`.** meibo's `publisher` waited on
`redpanda: condition: process_healthy`. A process that checks and exits is never "healthy",
so it had to become `process_completed_successfully`. meibo was the only project with a
dependency on the redpanda process; had it not been caught, `just process-up` would have hung
there rather than failing loudly.

**mori carried Colima wiring that existed only for `rpk container start`.** Its devshell had:

```text
# rpk uses the Docker Go SDK, which does not read Docker CLI contexts.
# Point it at Colima's socket when the caller has not selected a daemon.
if [ -z "''${DOCKER_HOST:-}" ]; then ... export DOCKER_HOST="unix://$_mori_docker_socket" ...
```

`rpk container` appeared nowhere else in mori and `DOCKER_HOST` appeared nowhere else either,
so removing the redpanda process made that block dead and it went with it. mori now needs no
Docker daemon at all for development. Worth checking for the same pattern in any project
migrated later — this is the kind of leftover that keeps a Colima dependency alive long after
the thing that needed it is gone.

**`hw-kafka-client` is not a migration candidate.** It is a fork of a third-party library
sitting on a feature branch (`fix/async-consumer-fatal-observability`) with a `PR_BODY.md`
next to it — an in-flight upstream contribution. Its `docker-compose.yml` and `shell.nix` are
upstream-owned files, and editing them would pollute that PR's diff and diverge from upstream
for no benefit to this initiative. Its compose file does collide with the shared cluster on
ports 8080, 8082, 9092, and 9644, so the two cannot run at once. Recorded as an explicit
exception rather than migrated; see the Decision Log.

**Every project was already namespacing its topics.** `mori.v1`, `mori.project.v1`,
`meibo.v1` — all prefixed with the owning project. The convention this plan was going to
invent already exists in practice; what is missing is it being written down anywhere a
newcomer would find it. That reframes the remaining documentation work from "establish a
convention" to "state the one already in use, and say why it matters now that the cluster is
shared".


## Decision Log

- Decision: Make this a separate child plan rather than a milestone inside plan 4.
  Rationale: plan 4
  (`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`)
  is about changing *this machine's configuration* — adding the flake input, importing the
  module, generating the `rpk` profile, writing the operator's runbook. Its audience is the
  person administering the machine. This plan changes *other repositories* and its audience
  is whoever writes tests in them, including coding agents that will read the guide without
  any of this initiative's context. The two have different blast radii: a mistake in plan 4
  breaks `darwin-rebuild switch`, a mistake here breaks somebody's test suite. Plan 4 was
  also already carrying seven progress items across adoption, profile generation,
  verification, runbook, rollback, and documentation, so folding a cross-repository
  migration into it would have made it the plan doing most of the work — which the
  decomposition principles in `agents/skills/master-plan/MASTERPLAN.md` warn against.
  Date: 2026-08-09

- Decision: Depend on plan 4 rather than plan 3.
  Rationale: this plan's instructions tell people to rely on an `rpk` profile that resolves
  without per-project configuration, and that profile is generated by plan 4. Writing a
  guide against a cluster that exists but is not yet the machine's default would mean
  documenting `--brokers 127.0.0.1:9092` everywhere and then rewriting the guide once the
  profile lands.
  Date: 2026-08-09

- Decision: Migrate the consumers before writing the guide, inverting this plan's milestone
  order.
  Rationale: the plan puts the guide in milestone 2 and the migrations in milestone 3, on the
  reasoning that conventions should be settled first. In practice the migrations *were* the
  research: they revealed that nine projects are involved rather than three, that every one
  already namespaces its topics, and that exactly one has a real clean-state requirement. A
  guide written first would have documented an invented convention and then needed rewriting
  against what the code actually does. The guide is still owed and is now better informed.
  Date: 2026-08-09

- Decision: Replace each project's broker process with a reachability check that exits
  non-zero and prints the fix, rather than deleting the process outright.
  Rationale: the plan offered both. Deleting it is simpler but moves the failure downstream —
  a developer with the cluster stopped gets a connection error from inside a Kafka client
  rather than a sentence telling them to run `redpanda-up`. The check costs one short process
  and turns the most common failure into a self-answering one.
  Date: 2026-08-09

- Decision: Destructive-command policy — no project may run `rpk container purge`,
  `rpk container stop`, or any delete-all-topics loop against the shared cluster. A project
  needing a clean slate resets **its own prefixed topics** instead.
  Rationale: this is the policy the plan asked for, and meibo is the case that shows what it
  must permit. Its need for a clean `meibo.v1` between runs is legitimate; what is not is
  achieving it by destroying a cluster eight other projects share. Deleting a prefixed topic
  is exactly as effective for the project's own state and cannot affect anyone else, which
  was demonstrated before committing it. All nine migrated projects were checked and none
  retains a live `rpk container` command.
  Date: 2026-08-09

- Decision: Do not migrate `hw-kafka-client`; record it as a documented exception.
  Rationale: the plan explicitly asked for this call to be made deliberately. It is a fork of
  an upstream third-party library, currently on a feature branch with a `PR_BODY.md` beside
  it, so its `docker-compose.yml` and `shell.nix` belong to upstream rather than to this
  machine's conventions, and editing them would pollute an in-flight PR diff. Its compose
  file binds 8080, 8082, 9092, and 9644, so it and the shared cluster cannot run at the same
  time: run `redpanda-down` first if you need it. A developer who only wants its test suite
  can set `KAFKA_TEST_BROKER=127.0.0.1` against the shared cluster and skip compose entirely,
  with no file changes at all.
  Date: 2026-08-09

- Decision: Leave `MORI_KAFKA_BROKERS` unset in mori's devshell.
  Rationale: mori gates its integration publisher on that variable, and its own ADR 0025 and
  plan 151 treat the gate as deliberate. Exporting it in the devshell would silently enable
  publishing for anyone entering `nix develop`, which is a behavioural change to a daily-use
  tool rather than part of moving where the broker comes from. Those are separate decisions
  and only the first was asked for.
  Date: 2026-08-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### What "the shared cluster" means here

Plans 1 through 4 of this MasterPlan produce a single Redpanda broker and a Redpanda
Console running as Apple Container containers, started at login by a launchd agent that
`home-manager` installs. *Redpanda* is a streaming data platform that speaks the Kafka
protocol, so anything that can talk to Kafka can talk to it. *Apple Container* is Apple's
macOS container runtime, which runs each Linux container as a lightweight virtual machine;
it replaces the Docker-inside-Colima arrangement this machine used before.

The cluster is **one shared long-lived instance**, not one per project. That is a
deliberate decision recorded in the MasterPlan's Decision Log: it directly replaces the
single shared Homebrew-Redpanda-on-Colima setup that came before, and per-project clusters
would multiply memory use and force dynamic port allocation.

Its fixed addresses, which this plan's guide must state and which are fixed in the
MasterPlan's Integration Point 4:

```text
127.0.0.1:9092   Kafka API
127.0.0.1:9644   Admin API
127.0.0.1:8081   Schema Registry
127.0.0.1:8082   HTTP Proxy
127.0.0.1:8080   Redpanda Console (web UI)
```

Five shell commands manage its lifecycle, provided by plan 3: `redpanda-up`,
`redpanda-down`, `redpanda-status`, `redpanda-logs`, `redpanda-purge`.

### The consuming projects, as they exist today

Three projects on this machine start their own Kafka. All live under
`/Users/shinzui/Keikaku/bokuno/`. Read each one before changing it; the descriptions below
were accurate on 2026-08-09 but these are active repositories.

**`kafka-effectful`** starts Redpanda through `process-compose`, a process supervisor that
reads a YAML file and runs the listed processes together. Its
`/Users/shinzui/Keikaku/bokuno/kafka-effectful/process-compose.yaml` contains:

```yaml
processes:
  redpanda:
    command: rpk container start -n 1 --kafka-ports 9092
    shutdown:
      command: rpk container purge
    readiness_probe:
      exec:
        command: "rpk cluster info"
      initial_delay_seconds: 5
      period_seconds: 5
```

Two things here matter enormously. `rpk container start` is the command that drives Docker,
and therefore Colima — it is precisely the dependency this whole initiative removes. And
`rpk container purge` **deletes the cluster and all its data**; as a shutdown hook it is
harmless when the cluster is that project's own, and catastrophic if it is ever pointed at
a cluster three other projects are using.

Its `Justfile` also has recipes that call `rpk topic create` and `rpk topic delete` with
bare, unprefixed topic names such as `kafka-effectful-sync-demo`, `source`, `destination`,
and `otel-demo`. `source` and `destination` are exactly the kind of generic name that will
collide with another project.

**`hw-kafka-streamly`** follows the same `process-compose` pattern, with its own `Justfile`
recipes in a `kafka` group.

**`hw-kafka-client`** takes a different route:
`/Users/shinzui/Keikaku/bokuno/hw-kafka-client/docker-compose.yml` defines a Redpanda
service pinned to `v23.1.1` plus a Console, publishing host ports 8082, 9092, 9644, 28082,
and 29092. Being `docker-compose`, it needs a Docker daemon and therefore Colima. Note the
old version and the extra ports — this one may be better left alone and simply documented,
which is a decision this plan must make rather than assume.

### Why topic namespacing is the central problem

With a single shared cluster, every project sees every topic. Two failure modes follow, and
the guide must prevent both.

The first is **collision**: two projects that both create a topic called `source` are
writing to the same topic. Tests then read each other's messages and fail in ways that look
like flakiness rather than interference.

The second is **destructive cleanup**: a test suite that tidies up after itself by deleting
every topic, or by calling `rpk container purge`, destroys other projects' data. With a
per-project cluster that was safe; with a shared cluster it is not.

The fix for both is a naming convention plus a prohibition, and this plan must choose them
concretely rather than gesture at them. A reasonable shape, to be confirmed during
implementation: every topic a project creates is prefixed with the project's name, and
test-created topics carry a further unique component so that concurrent runs of the *same*
suite do not collide either.

### What plan 4 provides that this plan relies on

Plan 4 (`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`)
generates an `rpk` profile so that `rpk` invocations reach the shared cluster from any
directory with no per-project configuration. That is what lets the guide say `rpk topic
list` rather than `rpk topic list --brokers 127.0.0.1:9092` everywhere.

Note that `~/Library/Application Support/rpk/rpk.yaml` currently holds a profile named
`rpk-container`, left behind by the Colima setup, already pointing at
`127.0.0.1:9092`, `127.0.0.1:9644`, and `127.0.0.1:8081`. It is `current_profile`. So `rpk`
commands without `--brokers` already resolve to those ports today; plan 4 replaces or
re-points this profile deliberately rather than relying on the leftover.

### Findings from the spike that this plan must respect

The spike, `docs/spikes/1-apple-container-redpanda-findings.md`, established two operational
facts that a testing guide has to account for.

Container-to-container networking on Apple Container **degrades and is repaired by
restarting the runtime** (`container system stop && container system start`). A test suite
that suddenly cannot reach the cluster may be hitting this rather than a bug in its own
code, and the guide should say so and give the remedy.

The broker becomes ready roughly one second after its container is running, and the reliable
readiness check is `curl -sf http://127.0.0.1:9644/v1/status/ready` returning
`{"status":"ready"}`. `rpk cluster info` also works and is what the existing
`process-compose` readiness probes use.

### ADR context

There is no `docs/adr/` directory in this repository, and no `mori.dhall`, so there is no
profile-governed OKF ADR bundle here. A Mori registry search during MasterPlan creation
found no cross-repository decisions about container runtimes or Redpanda
(`mori registry search redpanda` returned no projects).

**No relevant ADR exists yet.** This plan is, however, a strong ADR producer: the topic
namespacing convention and the prohibition on destructive commands against the shared
cluster are exactly the kind of durable, cross-repository constraint that a future
contributor in an unrelated project needs to discover without reading this plan. Promote
them to `docs/adr/` as part of completing this plan, and cross-reference from the guide.


## Plan of Work

Three milestones: decide the conventions, write the guide, then prove it by migrating real
consumers. The order matters — writing the guide before migrating anything would produce
advice nobody has tested, and migrating before deciding the conventions would bake ad-hoc
choices into three repositories.

### Milestone 1 — Inventory and conventions

At the end of this milestone there is a written, justified answer to three questions, and
nothing has been changed in any other repository yet.

First, complete the inventory. The three projects named in Context and Orientation were
found with a search for Kafka and Redpanda references under
`/Users/shinzui/Keikaku/bokuno/`; repeat that search rather than trusting the list, because
these are active repositories. Look for `process-compose.yaml`, `docker-compose.yml`,
`rpk container start`, and hard-coded `9092` in test configuration.

Second, decide the **topic namespacing convention**. It must answer: what prefix does a
project use, how do concurrent runs of the same suite avoid colliding with each other, and
how does a suite clean up only its own topics. Write the exact string form, not a
description of one.

Third, decide the **destructive-command policy**. `rpk container purge`, `rpk container
stop`, and any "delete all topics" loop are the dangerous ones. Decide what replaces each
in a shared world, and whether anything should actively prevent the dangerous form — for
example, whether `redpanda-purge` from plan 3 should require a confirmation. Record the
decision either way.

### Milestone 2 — The guide

At the end of this milestone `docs/using-the-shared-cluster.md` exists in this repository
and is complete enough that someone who has never read this MasterPlan can follow it.

It must cover, at minimum: the cluster's addresses and how to check it is running; how to
point a Kafka client at it, with a concrete example in the language the consuming projects
use; the topic namespacing convention from milestone 1, with examples; how to make a test
suite wait for readiness rather than fail on a cold start; the destructive commands that are
now forbidden and what to use instead; how to see what is in the cluster, including Console
at `http://127.0.0.1:8080`; the `container system stop && container system start` remedy for
the networking degradation the spike found; and the escape hatch — how to run a private
throwaway cluster when a test genuinely needs isolation, and when that is justified.

Write it for a reader who is either a developer new to the machine or a coding agent with
no context. That means no references to "the MasterPlan" or "plan 3" as though the reader
has them open; state the facts directly.

### Milestone 3 — Prove it by migrating real consumers

At the end of this milestone the guide is no longer theoretical.

Migrate `kafka-effectful` first, because its `process-compose.yaml` is the clearest case.
The `redpanda` process either disappears entirely — the shared cluster is always running, so
there is nothing to start — or becomes a readiness gate that waits for the shared cluster
and fails with a helpful message if it is down. Prefer the latter: a suite that fails with
"the shared Redpanda is not running, start it with `redpanda-up`" is far kinder than one
that fails with a connection refused deep in a Kafka client. The `rpk container purge`
shutdown hook must go. Its `Justfile` topic names must move to the new convention.

Then `hw-kafka-streamly`, which should be nearly identical.

Then decide what to do about `hw-kafka-client`. Its `docker-compose.yml` pins Redpanda
v23.1.1 and publishes five ports; migrating it means it can no longer be tested against that
specific old version. It may be correct to leave it as an explicitly documented exception —
"this project runs its own cluster, stop the shared one first" — rather than migrate it.
Make that call deliberately and record it.

Finally, prove the headline outcome: two projects' suites running simultaneously against the
shared cluster without interfering.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/redpanda-container` unless stated
otherwise.

### Step 1 — confirm the shared cluster is up

```bash
redpanda-status
curl -sf http://127.0.0.1:9644/v1/status/ready
```

Expect the status command to report the broker and Console running, and the curl to print
`{"status":"ready"}`. If not, run `redpanda-up` and wait.

### Step 2 — redo the consumer inventory

```bash
cd /Users/shinzui/Keikaku/bokuno
grep -rl -iE "rpk container start|redpandadata/redpanda|kafka" \
  --include=process-compose.yaml --include=docker-compose.yml --include=Justfile \
  . 2>/dev/null | grep -v dist-newstyle | sort
```

Expect at least `kafka-effectful`, `hw-kafka-streamly`, and `hw-kafka-client`. Investigate
anything else that appears.

### Step 3 — write the guide

Create `docs/using-the-shared-cluster.md` covering the contents listed in milestone 2.

### Step 4 — migrate `kafka-effectful`

```bash
cd /Users/shinzui/Keikaku/bokuno/kafka-effectful
$EDITOR process-compose.yaml     # remove the redpanda process / replace with a readiness gate
$EDITOR Justfile                 # namespace topic names, drop purge
just test
```

Expect the suite to pass with Colima stopped. Confirm Colima really is stopped:

```bash
colima status    # expect "colima is not running"
```

### Step 5 — migrate `hw-kafka-streamly`

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly
$EDITOR process-compose.yaml
$EDITOR Justfile
just test
```

### Step 6 — prove concurrent use

Run both suites at once, from two shells, and afterwards inspect the topic list:

```bash
rpk topic list
```

Expect each project's topics under its own prefix, and no topic belonging to one project
that the other created.


## Validation and Acceptance

This plan is complete when all of the following hold.

**The guide stands alone.** `docs/using-the-shared-cluster.md` can be handed to someone with
no knowledge of this initiative and they can connect a new project to the shared cluster
from it, without asking a question that the guide should have answered.

**Two suites run simultaneously without interference.** With Colima stopped, running
`kafka-effectful`'s and `hw-kafka-streamly`'s test suites at the same time both pass. This
is the acceptance that proves namespacing works; it is not provable by running them one at a
time.

**No migrated project can destroy the shared cluster by accident.** Grep the migrated
repositories and confirm nothing invokes `rpk container purge` or `rpk container stop`:

```bash
cd /Users/shinzui/Keikaku/bokuno
grep -rn "rpk container" kafka-effectful hw-kafka-streamly 2>/dev/null | grep -v dist-newstyle
```

Expect no output.

**A cold start fails helpfully.** With the shared cluster stopped (`redpanda-down`), running
a migrated project's test suite produces a message naming the problem and the fix, not a
bare connection error:

```text
The shared Redpanda cluster is not running. Start it with: redpanda-up
```

Then `redpanda-up` and the same command succeeds.

**Data survives.** After both suites have run, `redpanda-down && redpanda-up`, and confirm
with `rpk topic list` that topics are still present — the shared cluster's persistence is
part of what makes it usable, and this catches a misconfigured volume.


## Idempotence and Recovery

Writing the guide is idempotent; it is a document.

The consumer migrations are ordinary edits to files under version control in their own
repositories. Each project should be migrated and verified in its own commit so a single
project can be reverted without touching the others. Before editing any consumer, confirm
its working tree is clean so the migration is separable from unrelated in-flight work.

Nothing in this plan is destructive to the shared cluster, with one exception to be careful
about: while migrating a project away from `rpk container purge`, do not run that command to
"test" it. It deletes clusters and their data. If the shared cluster is ever destroyed,
plan 3's `redpanda-up` recreates it, but every topic and message in it is gone.

If a migration turns out to be wrong — for example a suite genuinely needs an empty cluster
and namespacing is not sufficient — the recovery is the escape hatch documented in milestone
2: that project runs a private throwaway cluster on non-default ports. Record the case in
Surprises & Discoveries, because it is evidence about the limits of the shared-cluster
decision and may eventually justify revisiting the MasterPlan's "one shared cluster" choice.


## Interfaces and Dependencies

**Consumed from plan 3**
(`docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md`):

- The wrapper commands `redpanda-up`, `redpanda-down`, `redpanda-status`, `redpanda-logs`,
  and `redpanda-purge`, which the guide instructs readers to use.

**Consumed from plan 4**
(`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`):

- The `rpk` profile that makes bare `rpk` commands reach the shared cluster from any
  directory. This is a hard dependency; without it the guide would have to spell out
  `--brokers 127.0.0.1:9092` on every command.
- The host port contract (MasterPlan Integration Point 4), which the guide restates.

**Consumed from the spike** (`docs/spikes/1-apple-container-redpanda-findings.md`):

- The readiness check `curl -sf http://127.0.0.1:9644/v1/status/ready`.
- The fact that Apple Container's networking degrades and is repaired by
  `container system stop && container system start`.

**Produced by this plan:**

- `docs/using-the-shared-cluster.md` — the guide.
- The topic namespacing convention and destructive-command policy, promoted to `docs/adr/`.
- Migrated `process-compose.yaml` and `Justfile` files in
  `/Users/shinzui/Keikaku/bokuno/kafka-effectful` and
  `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`.
- A recorded decision about `/Users/shinzui/Keikaku/bokuno/hw-kafka-client`.

**External tools used:**

- `rpk` v26.2.1 — `topic list|create|delete`, `cluster info`.
- `process-compose` — the process supervisor the two Haskell projects use.
- `cabal test` / `just test` — the consuming projects' test entry points.
- `curl` — readiness probes.
