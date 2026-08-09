---
title: No compiled CLI for local Redpanda; a home-manager module with shell wrappers instead
status: accepted
date: 2026-08-09
---

# No compiled CLI for local Redpanda

## Status

Accepted, 2026-08-09.

## Context

This repository exists to run a Redpanda cluster locally on Apple Container. The document
that started it, `docs/initial-spec.md`, argues at length for something quite different: a
compiled command-line tool built around a `Runtime` interface with Docker, Podman, and Apple
Container implementations, plus cluster metadata persistence, runtime capability detection,
and dynamic host-port allocation.

That design is a reasonable one — it is essentially what Redpanda's own `rpk container start`
does, and `rpk` needs it. `rpk` must serve every user on every runtime, with clusters of
arbitrary size, where one invocation creates a cluster and a later, unrelated invocation has
to find and manage it. Under those constraints you need a runtime abstraction, you need to
persist metadata about what you created, and you need to allocate ports dynamically because
you cannot know what else is running.

This machine has none of those constraints. There is one runtime, one shared single-broker
cluster, and fixed well-known ports.

## Decision

Ship a Nix flake exporting a `home-manager` module that generates shell wrappers. Do not
build a compiled tool, and do not implement a runtime abstraction.

Once the machinery that exists to serve `rpk`'s constraints is removed, what remains of the
specification is: create a volume, create a network, run two containers, poll for readiness,
and write an `rpk` profile. That is a shell script. Rendering it from Nix additionally makes
every value — image tags, ports, names, labels, resource limits — a typed option with a
default, which is most of what the "configuration" part of a compiled tool would have
provided.

This also matches how comparable services are already managed on this machine:
`home/postgresql.nix` and `home/victorialogs.nix` in the dotfiles repository are the same
shape.

## Consequences

The implementation is roughly 300 lines of Nix and shell instead of a Go or Haskell project
with its own build, test suite, and release process. It has no unit tests; correctness is
established by running the five commands and observing behaviour, which is proportionate for
something whose entire job is assembling command lines.

The wrappers are linted rather than tested: they are built with `writeShellApplication`,
which runs `shellcheck` at build time and fails the build on a warning. That catches the
class of bug — unquoted expansions, mostly — that actually afflicts scripts like these.

Because there is no runtime abstraction, this works on Apple Container and nowhere else.
That is stated rather than regretted; Colima and Docker remain installed on this machine as
a fallback, so nothing is lost by declining to abstract over them.

## Reversal criteria

Recorded so this is not re-litigated from memory. Build the compiled tool when any of the
following is actually needed, rather than hypothetically:

- **Multi-broker clusters.** Seed-server bootstrapping and per-broker argument construction
  are genuinely awkward in shell and genuinely want unit tests.
- **Per-project isolated clusters.** More than one cluster at a time means port-collision
  handling, which is the thing fixed ports currently buy us.
- **Dynamic port allocation.** Discovering free ports and recording which cluster got which
  is exactly the metadata-persistence problem the specification describes.

Until one of those is real, the shell approach is not a compromise; it is the smaller correct
solution. Note that the module's internals are already fully parameterised — names, ports,
labels, and the purge filter all come from options rather than constants — so adding a second
instance is configuration rather than redesign, and reaching one of these criteria does not
necessarily mean a rewrite.

## References

- `docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md` — the initiative,
  its scope, and the alternatives considered.
- `docs/initial-spec.md` — the specification this decision declines to implement.
- `docs/adr/2-redpanda-container-naming-and-port-contract.md` — the contract the wrappers
  depend on.
