---
title: Resource naming, labelling, and host-port contract for the local Redpanda cluster
status: accepted
date: 2026-08-09
---

# Resource naming, labelling, and host-port contract

## Status

Accepted, 2026-08-09.

## Context

The local Redpanda cluster is not self-contained. Several things need to agree on what its
resources are called: the wrapper scripts that create and destroy them, anything that
inspects or cleans up containers on this machine, the `rpk` profile that points clients at
it, and any future tooling that has to coexist with it without stepping on it.

There is a specific hazard. `rpk container start` — the Docker-based path this replaces, and
which remains installed as a fallback — creates its own Redpanda containers with its own
labels (`cluster-id=redpanda`, `node-id=<n>`). A cleanup routine that matched loosely could
delete the wrong cluster.

## Decision

Fix the following contract. These are option defaults in the `home-manager` module, not
constants in the shell, but changing them is a coordinated change across everything listed
in Consequences.

**Resource names**

```text
network:            redpanda
broker container:   redpanda-0
console container:  redpanda-console
broker volume:      redpanda-0-data
launchd label:      com.shinzui.redpanda
host state dir:     ~/.local/state/redpanda
```

**Labels**, applied to every container this module creates:

```text
dev.shinzui.redpanda.managed=true
dev.shinzui.redpanda.role=broker | console
dev.shinzui.redpanda.node-id=0            (broker only)
```

**Host ports**, all bound to `127.0.0.1` only:

```text
9092  Kafka API        (broker's external listener, container port 19092)
9644  Admin API        (container port 9644; also serves /v1/status/ready)
8081  Schema Registry  (external listener, container port 18081)
8082  HTTP Proxy       (external listener, container port 18082)
8080  Redpanda Console (container port 8080)
```

The `dev.shinzui.redpanda.` label prefix is deliberately unlike `rpk container start`'s
labels so the two can never be confused. `redpanda-purge` filters strictly on
`dev.shinzui.redpanda.managed=true` and refuses to delete a container that does not carry it.

Ports bind to loopback rather than all interfaces so the cluster is not reachable from
outside the machine. These five were checked against everything else listening here —
VictoriaLogs 9428, VictoriaTraces 10428, Jaeger 16686, mina 8765, reiko 8770, rei kiroku
metrics 9091, Caddy 80 — and none collide. They also match the ports the pre-existing
`rpk-container` profile already used, so the profile is substitutable.

## Consequences

Anything that inspects or cleans up these containers must filter on the label prefix, not on
container names, because names are options and a second instance would use different ones.
Apple Container's `container list` has **no server-side label filtering**, so filtering
happens in `jq` against `.configuration.labels`. The resource's name is at top-level `.id`
for containers, volumes, and networks alike.

The `rpk` profile depends on the four client-facing ports. Changing a port means changing the
profile in the same commit.

Because ports are fixed rather than allocated, exactly one instance of this cluster can run
at a time. That is the intended trade — see
`docs/adr/1-no-compiled-cli-for-local-redpanda.md`, where dynamic port allocation is one of
the criteria for reconsidering the whole approach. A project needing a private cluster must
choose its own ports explicitly.

The launchd label follows the `com.shinzui.<name>` convention used by every other user
service on this machine. Note that Apple Container's *own* agent does not: it registers
`com.apple.container.apiserver` in the `user/<uid>` launchd domain rather than the
`gui/<uid>` domain everything else here uses, so code that inspects the two must not assume
one domain.

## Notes on values that are not free choices

Two entries above are determined by Redpanda and Apple Container rather than by preference,
and changing them will not work.

The broker's data directory inside the container is `/var/lib/redpanda/data`, and the image
runs as `uid=101(redpanda)`. A freshly created Apple Container volume mounts root-owned and
masks the image's correctly-owned directory, so the volume must be chowned to `101:101`
before first use or the broker dies at startup with a permission error.

The internal advertised address (`redpanda-0`) is a name that nothing resolves on its own.
Apple Container has no container-to-container name resolution, so Console gets a generated
hosts file bind-mounted over `/etc/hosts`. Evidence for both is in
`docs/spikes/1-apple-container-redpanda-findings.md`.

## References

- `docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md` — Integration
  Points 2 and 4, where this contract is coordinated across plans.
- `docs/spikes/1-apple-container-redpanda-findings.md` — the verified behaviour behind the
  non-obvious entries.
