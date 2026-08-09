# First-Class Apple Container Support for `rpk container`

## Status

Proposed

## Summary

Add Apple’s native `container` runtime as a supported backend for:

```text
rpk container start
rpk container stop
rpk container status
rpk container purge
```

The goal is for Apple Silicon macOS users to run local Redpanda clusters without Docker Desktop, Colima, or Podman.

Apple Container should be treated as another implementation of the existing local-container abstraction, alongside Docker and Podman.

Target UX:

```bash
rpk container start --runtime apple
```

and, when no runtime is explicitly selected:

```bash
rpk container start
```

should automatically use Apple Container when:

1. the host is macOS,
2. the `container` executable is installed and operational,
3. Docker/Podman selection has not been explicitly requested.

No changes to the Redpanda server are expected.

---

# 1. Goals

## Primary goals

Support local single-node and multi-node Redpanda clusters using Apple's `container` CLI.

Support:

* Redpanda broker containers
* Redpanda Console
* OCI image pulling
* persistent broker storage
* Kafka listeners
* Admin API
* Schema Registry
* HTTP Proxy
* broker RPC
* host port publishing
* multi-broker networking
* cluster lifecycle management
* existing `rpk` profile creation
* `rpk container status`
* `rpk container stop`
* `rpk container purge`

Preserve the existing user experience of:

```bash
rpk container start -n 3
```

as much as practical.

## Secondary goals

Introduce a sufficiently clean runtime abstraction that additional OCI runtimes can be added later without embedding runtime-specific conditionals throughout the cluster orchestration code.

---

# 2. Non-goals

This feature is not intended to:

* support production deployments
* make `rpk redpanda start` run natively on macOS
* replace Kubernetes deployment mechanisms
* provide Docker API compatibility
* implement Docker Compose compatibility
* emulate every Docker CLI feature
* support Intel Macs in the initial implementation
* provide production disk or CPU tuning
* guarantee production-equivalent I/O performance

`rpk container` remains a development and testing environment.

---

# 3. Platform Requirements

Initial support:

```text
OS: macOS
Architecture: arm64 / Apple Silicon
macOS: version supported by Apple Container networking
Runtime: Apple container CLI
```

Before starting a cluster, validate:

```bash
container --version
```

and verify that the runtime service is usable.

Failure should produce an actionable message such as:

```text
Apple Container is installed but unavailable.

Verify that the container service is running:

    container system start

Or select another runtime:

    rpk container start --runtime docker
```

Exact commands should be verified against the supported Apple Container release.

---

# 4. Runtime Selection

Introduce an explicit runtime option.

```bash
rpk container start --runtime auto
rpk container start --runtime docker
rpk container start --runtime podman
rpk container start --runtime apple
```

Valid values:

```text
auto
docker
podman
apple
```

Default:

```text
auto
```

The same runtime selection must apply to lifecycle commands where runtime discovery is necessary.

## Auto-detection

Runtime detection should be deterministic.

Suggested precedence:

```text
1. explicitly configured runtime
2. existing cluster's recorded runtime
3. Docker, if available
4. Podman, if available
5. Apple Container, if available on macOS
```

Alternatively, Apple Container may be preferred over Docker on macOS, but changing existing Docker behavior should be considered separately because it would be a behavior change for existing users.

The safest initial implementation is therefore:

```text
Docker -> Podman -> Apple Container
```

for `auto`.

Users wanting Apple Container can explicitly select:

```bash
rpk container start --runtime apple
```

A future release can revisit the default.

---

# 5. Runtime Abstraction

Create a runtime interface representing only operations required by `rpk container`.

Conceptually:

```go
type Runtime interface {
    Name() string

    Available(ctx context.Context) error

    PullImage(ctx context.Context, image string) error

    CreateNetwork(
        ctx context.Context,
        spec NetworkSpec,
    ) error

    RemoveNetwork(
        ctx context.Context,
        name string,
    ) error

    CreateVolume(
        ctx context.Context,
        spec VolumeSpec,
    ) error

    RemoveVolume(
        ctx context.Context,
        name string,
    ) error

    RunContainer(
        ctx context.Context,
        spec ContainerSpec,
    ) (Container, error)

    StopContainer(
        ctx context.Context,
        id string,
    ) error

    RemoveContainer(
        ctx context.Context,
        id string,
    ) error

    InspectContainer(
        ctx context.Context,
        id string,
    ) (ContainerState, error)

    ListContainers(
        ctx context.Context,
        labels map[string]string,
    ) ([]Container, error)

    Logs(
        ctx context.Context,
        id string,
    ) (io.ReadCloser, error)
}
```

The exact interface should follow existing Redpanda architecture rather than necessarily using these method names.

The important architectural constraint is:

> Cluster orchestration must not construct Docker, Podman, or Apple CLI commands directly.

Runtime-specific command construction belongs in runtime implementations.

---

# 6. Common Container Specification

Represent the subset of OCI/container configuration required by Redpanda independently from the runtime.

Example:

```go
type ContainerSpec struct {
    Name       string
    Image      string
    Command    []string
    Env        map[string]string
    Labels     map[string]string

    CPUs       int
    Memory     int64

    Networks   []NetworkAttachment
    Ports      []PortMapping
    Volumes    []VolumeMount
}
```

For example:

```go
type PortMapping struct {
    HostIP        string
    HostPort      uint16
    ContainerPort uint16
    Protocol      string
}
```

and:

```go
type VolumeMount struct {
    Source      string
    Destination string
    ReadOnly    bool
}
```

Do not expose Docker-specific concepts in this common structure unless they are actually required by cluster orchestration.

---

# 7. Apple Container Runtime

Add an implementation conceptually named:

```text
AppleRuntime
```

or:

```text
ContainerRuntime
```

Avoid naming the Go package simply `container` if it conflicts with existing Redpanda package naming.

This implementation invokes Apple's:

```bash
container
```

CLI.

It does not require or attempt to use a Docker-compatible socket.

---

# 8. Image Handling

Redpanda images are OCI-compatible.

Use the same configured image currently accepted by:

```bash
rpk container start --image ...
```

For example:

```text
docker.redpanda.com/redpandadata/redpanda:<version>
```

or whatever image value the existing implementation resolves.

The runtime backend should translate image pulling into:

```bash
container image pull <image>
```

if an explicit pull is required.

When:

```bash
--pull
```

is supplied, force an explicit image pull before creating containers.

Otherwise allow Apple Container's normal image resolution behavior where appropriate.

No Rosetta support should be enabled for normal Redpanda images on Apple Silicon.

Prefer:

```text
linux/arm64
```

when an architecture must be specified.

---

# 9. Redpanda Development Configuration

Run brokers using Redpanda's development-container settings rather than production tuning.

Equivalent behavior should use:

```text
--mode dev-container
```

where possible.

Redpanda's current `dev-container` mode configures development-oriented behavior including overprovisioning, zero reserved memory, disabled system checks, and unsafe fsync bypass suitable for local/testing environments.

Do not implement production memory locking or production disk tuning as part of the initial feature.

---

# 10. Storage

Each Redpanda broker receives its own persistent named volume.

Suggested names:

```text
rpk-redpanda-0-data
rpk-redpanda-1-data
rpk-redpanda-2-data
```

Mount:

```text
<volume> -> /var/lib/redpanda/data
```

Apple Container supports named volumes and should be used instead of macOS bind mounts for broker data.

Benefits:

* Linux-native filesystem inside the VM
* avoids APFS/shared-directory semantics
* cleaner lifecycle management
* isolates broker data

Create with an equivalent of:

```bash
container volume create <name>
```

Run with:

```bash
-v <name>:/var/lib/redpanda/data
```

## Purge semantics

```bash
rpk container stop
```

must preserve volumes.

```bash
rpk container purge
```

must:

1. stop broker containers
2. remove broker containers
3. remove Console
4. remove the cluster network
5. remove broker data volumes
6. remove persisted local cluster metadata

Volume removal must happen only after all containers referencing the volume have been deleted.

---

# 11. Networking

Networking is the most important runtime-specific portion.

Create one dedicated network per local cluster.

Suggested name:

```text
rpk-redpanda
```

or a cluster-ID-qualified equivalent.

Example:

```bash
container network create rpk-redpanda
```

Attach every broker and Console container to this network.

Apple Container supports user-defined networks on supported macOS versions.

## Broker naming

Give each broker a stable DNS-resolvable name:

```text
redpanda-0
redpanda-1
redpanda-2
```

Containers must be able to reach one another through these names or an equivalent stable network identity.

Verify runtime DNS behavior during implementation.

If container-name DNS is not provided automatically, obtain stable container addresses from network/container inspection and construct broker configuration from those addresses.

Do not assume Docker's DNS behavior without testing it.

---

# 12. Listener Model

Each broker requires separate internal and externally advertised listener addresses.

For broker `N`:

Internal Kafka listener:

```text
0.0.0.0:9092
```

Internal advertised address:

```text
redpanda-N:9092
```

External listener:

```text
0.0.0.0:<container external port>
```

Externally advertised address:

```text
127.0.0.1:<published host port>
```

Follow the same internal/external listener strategy currently used by the Docker/Podman implementation wherever possible.

The key invariant is:

> Containers communicate through the cluster network, while clients running on macOS communicate through published localhost ports.

Do not advertise:

```text
localhost
```

to other brokers.

Do not advertise a VM-private address to host clients.

---

# 13. Port Publishing

Apple Container supports:

```bash
-p host-port:container-port
```

Translate existing `rpk container` port configuration into Apple CLI port publishing.

Existing flags must continue to work:

```text
--kafka-ports
--admin-ports
--rpc-ports
--schema-registry-ports
--proxy-ports
--console-port
--any-port
```

For example:

```bash
rpk container start \
  --runtime apple \
  --kafka-ports 9092 \
  --admin-ports 9644
```

should publish those ports to localhost.

---

# 14. Random Port Allocation

`--any-port` must remain supported.

Preferred implementation:

Allocate ports in `rpk` before container creation rather than depending on runtime-specific random-port behavior.

Process:

```text
select available host port
        ↓
record port
        ↓
configure Redpanda advertised listener
        ↓
publish that exact port
```

This keeps behavior identical across Docker, Podman, and Apple Container and avoids needing to inspect dynamically assigned runtime ports.

There is an unavoidable small race between selecting and binding a port; use the same mechanism already employed by the current implementation if one exists.

---

# 15. Multi-Broker Bootstrapping

For:

```bash
rpk container start -n 3 --runtime apple
```

create:

```text
redpanda-0
redpanda-1
redpanda-2
```

All brokers join the common network.

The first broker acts as the seed.

Other brokers use an internal address such as:

```text
redpanda-0:<rpc-port>
```

for seed discovery.

Start sequence should be:

```text
create network
    ↓
create broker volumes
    ↓
start broker 0
    ↓
wait until broker 0 is reachable internally/externally
    ↓
start remaining brokers
    ↓
wait for cluster membership
    ↓
start Console
    ↓
create rpk profile
```

Parallel creation of brokers may be retained if the existing architecture already handles seed startup safely.

---

# 16. Redpanda Console

Console should run as a separate Apple Container container using the existing Console image.

Connect Console to:

```text
rpk-redpanda
```

Configure its Kafka brokers using internal addresses:

```text
redpanda-0:9092
redpanda-1:9092
redpanda-2:9092
```

Publish:

```text
8080
```

or the value supplied through:

```text
--console-port
```

to the host.

Console must never use the brokers' host-side advertised addresses for container-to-container communication.

---

# 17. Runtime Metadata

Persist which runtime created the cluster.

For example:

```yaml
runtime: apple
cluster_id: ...
network: rpk-redpanda

nodes:
  - name: redpanda-0
    container_id: ...
    volume: rpk-redpanda-0-data
    kafka_port: 9092
    admin_port: 9644
```

This data should live alongside whatever cluster metadata `rpk container` currently persists.

Subsequent:

```text
status
stop
purge
```

commands must use the recorded runtime rather than re-running runtime auto-detection.

This prevents:

```text
start with Apple Container
install Docker later
stop accidentally searches Docker
```

---

# 18. Container Identification

Do not rely solely on human-readable names for discovery.

Attach labels to all resources where Apple Container supports them.

Suggested labels:

```text
io.redpanda.rpk.managed=true
io.redpanda.rpk.cluster=<cluster-id>
io.redpanda.rpk.role=broker
io.redpanda.rpk.node-id=0
```

Console:

```text
io.redpanda.rpk.role=console
```

Network and volume labels should also be added if supported.

If Apple Container's filtering capabilities are insufficient, persist IDs in cluster metadata and use those IDs directly.

---

# 19. Status

This command:

```bash
rpk container status
```

must return the same logical information regardless of runtime.

Example:

```text
NODE-ID  STATUS   KAFKA-ADDRESS     ADMIN-ADDRESS
0        running  127.0.0.1:9092   127.0.0.1:9644
1        running  127.0.0.1:10092  127.0.0.1:10644
2        running  127.0.0.1:11092  127.0.0.1:11644
```

Apple runtime implementation should use structured output where available.

Prefer:

```bash
container list --format json
container inspect ...
```

rather than parsing human-oriented table output.

JSON parsing should be isolated inside the Apple runtime implementation.

---

# 20. Stop Behavior

```bash
rpk container stop
```

should:

```text
stop Console
stop all brokers
```

but retain:

```text
containers, if existing semantics retain them
volumes
network
cluster metadata
```

Follow existing Docker/Podman semantics exactly where practical.

Restarting through the existing `rpk container` lifecycle should retain broker data.

---

# 21. Purge Behavior

```bash
rpk container purge
```

must be idempotent.

Missing resources should not cause purge to fail.

Equivalent desired sequence:

```text
stop console
stop brokers
remove console container
remove broker containers
remove volumes
remove network
delete cluster metadata
```

Partial previous failures should therefore be recoverable by running `purge` again.

---

# 22. Failure Handling

If a broker fails to start:

1. capture its logs
2. surface the relevant error
3. remove resources created during this invocation where safe
4. preserve enough information for troubleshooting

Example:

```text
Failed to start Redpanda node 1 using Apple Container.

Container logs:

<last relevant lines>

Run:

    container logs redpanda-1
```

Do not return opaque errors such as:

```text
exit status 1
```

without including stderr.

---

# 23. Apple Runtime Command Executor

Centralize external process invocation.

Example interface:

```go
type Commander interface {
    Run(
        ctx context.Context,
        command string,
        args ...string,
    ) ([]byte, error)
}
```

This enables runtime unit tests without invoking real VMs.

Apple runtime code should build argument arrays, never shell command strings.

Good:

```go
exec.CommandContext(ctx, "container", args...)
```

Avoid:

```go
exec.CommandContext(ctx, "sh", "-c", command)
```

This prevents quoting bugs and makes tests deterministic.

---

# 24. Runtime Capability Detection

Not every Apple Container release exposes identical features.

Add an internal capability representation if necessary:

```go
type RuntimeCapabilities struct {
    Networks       bool
    NamedVolumes   bool
    PublishPorts   bool
    Labels         bool
    JSONOutput     bool
}
```

At minimum, Apple backend startup must verify:

```text
network support
named volume support
port publishing
```

If required features are unavailable:

```text
Apple Container <version> does not support the networking features
required for multi-node Redpanda clusters.

Upgrade Apple Container or use Docker/Podman.
```

Potentially allow single-node operation on a more restricted runtime only if doing so does not complicate the implementation significantly.

---

# 25. Version Checks

Do not hard-code a minimum Apple Container version unless a feature actually requires it.

Instead:

1. detect version
2. detect required commands/features
3. return a meaningful compatibility error

Once compatibility is understood through CI and testing, establish an explicit minimum version.

---

# 26. CLI UX

Add runtime selection consistently.

Example:

```bash
rpk container start --runtime apple
```

Expected startup output:

```text
Using Apple Container runtime
Starting cluster...
Waiting for cluster to be ready...

Cluster started!

NODE-ID  STATUS   KAFKA-ADDRESS     ADMIN-ADDRESS
0        running  127.0.0.1:9092   127.0.0.1:9644

Console:
http://127.0.0.1:8080
```

Do not make users understand Apple Container networking internals.

---

# 27. Configuration

Optionally support persistent preference:

```yaml
container:
  runtime: apple
```

or whatever configuration hierarchy fits `rpk`.

CLI overrides config:

```text
CLI flag
    >
rpk config
    >
auto detection
```

This is optional for the first patch if it substantially expands scope.

The explicit CLI flag is required.

---

# 28. Testing Strategy

## Unit tests

Unit-test argument generation for:

```text
image pull
network create
network remove
volume create
volume remove
container run
container stop
container remove
container inspect
```

Example expectation:

Input:

```go
ContainerSpec{
    Name: "redpanda-0",
    Image: "...",
    Ports: []PortMapping{
        {
            HostPort: 9092,
            ContainerPort: 9092,
        },
    },
}
```

must generate the equivalent of:

```text
container run
--name redpanda-0
--network rpk-redpanda
-p 9092:9092
-v rpk-redpanda-0-data:/var/lib/redpanda/data
...
```

Do not assert one giant command string.

Assert argument slices.

---

# 29. Integration Tests

Run integration tests on Apple Silicon macOS.

## Test 1 — Single node

```bash
rpk container start \
  --runtime apple \
  -n 1
```

Verify:

```bash
rpk cluster info
```

Then:

```bash
rpk topic create test
echo hello | rpk topic produce test
rpk topic consume test -n 1
```

Expected:

```text
hello
```

---

## Test 2 — Three nodes

```bash
rpk container start \
  --runtime apple \
  -n 3
```

Verify:

```bash
rpk cluster health
```

Cluster should report all three brokers.

Create a replicated topic:

```bash
rpk topic create test \
  --partitions 3 \
  --replicas 3
```

Produce and consume data.

---

## Test 3 — Console

Verify:

```text
http://127.0.0.1:<console-port>
```

responds successfully.

Verify Console sees:

```text
all brokers
topics
partitions
```

---

## Test 4 — Restart persistence

Create a topic and produce data.

Run:

```bash
rpk container stop
```

Restart cluster.

Verify the previously produced message remains available.

---

## Test 5 — Purge

Run:

```bash
rpk container purge
```

Verify:

```text
containers removed
network removed
volumes removed
metadata removed
```

Running purge again should succeed.

---

## Test 6 — Random ports

```bash
rpk container start \
  --runtime apple \
  --any-port
```

Verify:

```text
rpk profile
```

contains the assigned Kafka addresses and connectivity works.

---

## Test 7 — Explicit ports

```bash
rpk container start \
  --runtime apple \
  --kafka-ports 19092,29092,39092 \
  -n 3
```

Verify all published addresses.

---

## Test 8 — Runtime persistence

Start with:

```bash
rpk container start --runtime apple
```

Ensure:

```bash
rpk container status
rpk container stop
rpk container purge
```

continue using Apple Container even if Docker becomes available afterward.

---

# 30. Manual Networking Tests

Before completing the implementation, explicitly verify these Apple Container behaviors.

### A. Container DNS

From `redpanda-1`:

```bash
ping redpanda-0
```

or equivalent name resolution check.

Confirm whether container names become DNS names on user-defined networks.

### B. Published ports

Confirm:

```text
macOS localhost
    ↓
published port
    ↓
container listener
```

works reliably.

### C. Container-to-container connectivity

Confirm Redpanda broker RPC and Kafka traffic can traverse the user-defined network.

### D. Volume persistence

Write data, stop/remove/recreate the broker container using the same volume, and verify data survives.

These four experiments should be done before designing workarounds.

---

# 31. CI

Add a macOS ARM64 integration job if Apple's runtime is available in the project's CI environment.

Conceptually:

```text
macOS ARM64 runner
    ↓
install Apple Container
    ↓
container system start
    ↓
build rpk
    ↓
rpk container start --runtime apple -n 3
    ↓
produce/consume smoke test
    ↓
rpk container purge
```

If suitable Apple Silicon CI is unavailable, retain the runtime unit tests in normal CI and maintain an explicitly documented manual integration suite until ARM runners can be introduced.

---

# 32. Documentation

Update:

```text
rpk container
rpk container start
local development quickstart
macOS prerequisites
```

Current documentation describes Docker or Podman as prerequisites. Update this to include Apple Container on supported Apple Silicon macOS systems.

Example:

```text
On macOS with Apple Silicon, rpk can use:

- Docker
- Podman
- Apple Container
```

Example startup:

```bash
rpk container start --runtime apple
```

Also document:

```text
Apple Container support is intended for local development and testing.
```

---

# 33. Implementation Phases

## Phase 1 — Runtime abstraction

Refactor current Docker/Podman implementation behind a common runtime interface.

Requirements:

* no user-visible behavior changes
* existing tests remain green

This should be a separate commit or PR where practical.

---

## Phase 2 — Apple backend

Implement:

```text
runtime detection
images
networks
volumes
run
stop
remove
inspect
logs
```

Add runtime unit tests.

---

## Phase 3 — Single-node Redpanda

Support:

```bash
rpk container start \
  --runtime apple \
  -n 1
```

Validate Kafka/Admin/Console connectivity.

---

## Phase 4 — Multi-node networking

Support:

```bash
-n 3
```

Validate:

```text
seed discovery
broker RPC
Kafka internal listeners
external advertised listeners
Console
```

---

## Phase 5 — Lifecycle

Implement and verify:

```text
status
stop
restart behavior
purge
```

---

## Phase 6 — CI and documentation

Add:

```text
integration tests
documentation
release notes
```

---

# 34. Acceptance Criteria

The feature is complete when all of the following work on an Apple Silicon Mac without Docker or Podman installed.

### Start

```bash
rpk container start --runtime apple
```

creates a working Redpanda cluster.

### Kafka

```bash
rpk topic create test

echo "hello" | rpk topic produce test

rpk topic consume test -n 1
```

works from macOS.

### Multi-node

```bash
rpk container purge

rpk container start \
  --runtime apple \
  -n 3
```

creates three healthy Redpanda brokers.

### Console

Redpanda Console is accessible from the host and connects to the brokers through their internal network.

### Status

```bash
rpk container status
```

reports correct node state and host addresses.

### Stop

```bash
rpk container stop
```

stops the cluster without deleting broker data.

### Persistence

Restarting retains existing topics and records.

### Purge

```bash
rpk container purge
```

removes:

```text
containers
network
volumes
cluster metadata
```

and is safe to run repeatedly.

### Runtime isolation

Docker and Podman are not required anywhere in the Apple Container execution path.

---

# 35. Key Design Constraint

The implementation should not look like:

```go
if docker {
    ...
} else if podman {
    ...
} else if apple {
    ...
}
```

spread throughout the cluster implementation.

Instead:

```text
               Cluster Orchestrator
                       │
                       ▼
                Runtime Interface
                 /      |       \
                /       |        \
           Docker    Podman     Apple
```

Cluster orchestration owns Redpanda concepts:

```text
brokers
listeners
seed servers
ports
Console
health
```

Runtime implementations own container concepts:

```text
images
containers
networks
volumes
process invocation
inspection
```

That separation is the central architectural requirement.

---

# 36. First Implementation Spike

Before doing the full refactor, validate Apple Container with a minimal shell-level spike.

The spike should prove only:

```text
OCI image works
named volume works
host port publishing works
Redpanda starts
Kafka from host works
two containers communicate over a network
```

Once those assumptions are proven, proceed with the runtime abstraction.

Do not merge the spike as the final implementation.

---

# 37. Definition of Done

A developer on an Apple Silicon Mac can install `rpk` and Apple Container and run:

```bash
rpk container start --runtime apple
```

without installing Docker Desktop, Docker Engine, Colima, or Podman, and receive the same practical local-development Redpanda experience currently provided by `rpk container`.

