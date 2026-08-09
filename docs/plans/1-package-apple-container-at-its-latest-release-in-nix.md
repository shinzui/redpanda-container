---
id: 1
slug: package-apple-container-at-its-latest-release-in-nix
title: "Package Apple Container at its latest release in Nix"
kind: exec-plan
created_at: 2026-08-09T00:15:00Z
intention: "intention_01kzhxfhpqekma79h936t7t2pk"
master_plan: "docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md"
---


# Package Apple Container at its latest release in Nix

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Apple ships a container runtime for macOS called `container`. It runs Linux containers as
lightweight virtual machines — one small VM per container — using Apple's Virtualization
and vmnet frameworks. It is a direct alternative to running Docker inside a Colima VM,
and it is the runtime this machine will use for local Redpanda.

Right now `container` is not installed on this machine at all:

```bash
$ which container
container not found
```

After this plan, `container` is installed by Nix, at the latest upstream release, and its
background service starts automatically when you log in. You will be able to run, from any
directory:

```bash
$ container --version
container CLI version 1.2.2 (build: release, commit: ...)

$ container system status
APISERVER  RUNNING
...

$ container run --rm docker.io/library/alpine:latest echo "hello from a Linux VM"
hello from a Linux VM
```

That last command is the whole point: a Linux container ran on this Mac, and Colima was
never started. Nothing about Redpanda happens in this plan — this plan only makes the
runtime exist and be managed declaratively like everything else on the machine.

This is child plan 1 of the MasterPlan at
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`. Every other child
plan depends on this one, because none of them can run a container until `container`
exists.


## Progress

- [ ] Write `derivations/apple-container.nix` in the dotfiles repository, pinned to 1.2.2
- [ ] Expose it through the `my-packages` overlay as the attribute `container`
- [ ] Add `container` to `home.packages` in `home/default.nix`
- [ ] Verify the derivation builds in isolation with `nix build`
- [ ] Run `darwin-rebuild switch` and confirm `container --version` reports 1.2.2
- [ ] Add a `home-manager` activation or launchd arrangement that runs `container system start`
- [ ] Confirm the service survives a logout/login (or a reboot) without manual intervention
- [ ] Confirm `container run --rm ... echo` works with Colima stopped
- [ ] Record findings, decisions, and the retrospective in this plan


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Carry a local copy of the nixpkgs `container` derivation pinned to 1.2.2
  rather than using `pkgs.container` directly or `overrideAttrs`-ing it.
  Rationale: nixpkgs-unstable currently ships 1.1.0. An `overrideAttrs` that changes only
  `version` and `src.hash` would silently break if nixpkgs later changes the derivation's
  internals (for example, if it stops using `fetchurl` or renames the wrapper phase). A
  local copy is 60 lines, makes the pinned version an explicit reviewable fact, and is the
  same approach the repository already takes for `tmuxai`, `oq`, `uuinfo`, `hunk`, and
  others under `derivations/`.
  Date: 2026-08-08

- Decision: Name the overlay attribute `container`, shadowing nixpkgs' own `container`.
  Rationale: the MasterPlan's Integration Point 1 requires a stable attribute name, and
  shadowing means that if nixpkgs later catches up, deleting the local derivation and the
  overlay line is the entire migration. The alternative name `apple-container` would
  require touching every consumer at that point.
  Date: 2026-08-08


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The two repositories

All work in this plan happens in `/Users/shinzui/Keikaku/dotfiles.nix`, which is a Nix
flake that configures this entire Mac. It is a separate git repository from the one this
plan file lives in (`/Users/shinzui/Keikaku/bokuno/redpanda-container`). When this plan
says "the dotfiles repository" it means the former.

The dotfiles repository is a `flake-parts` flake. Its top-level `flake.nix` imports four
modules from `flake-modules/`:

- `flake-modules/overlays.nix` — defines `flake.overlays`, a set of nixpkgs overlays. An
  *overlay* is a function that adds or replaces package attributes in the package set. The
  one that matters here is `my-packages`, which is where every locally-defined package is
  registered.
- `flake-modules/packages.nix` — defines per-system `packages` outputs, so individual
  packages can be built with `nix build .#<name>` without rebuilding the whole system.
- `flake-modules/darwin-configurations.nix` — assembles the `nix-darwin` system
  configuration named `SungkyungM1X`, which is what `darwin-rebuild switch` builds.
- `flake-modules/modules.nix` — exports reusable modules; not needed by this plan.

Locally-defined package derivations live in `derivations/`. Some are single `.nix` files
(`derivations/oq.nix`), some are directories with a `default.nix`
(`derivations/hunk/default.nix`). Either shape works.

User-level packages and services are configured by `home-manager`, whose entry point is
`/Users/shinzui/Keikaku/dotfiles.nix/home/default.nix`. That file has a long
`home.packages` list; around line 220 it currently contains:

```nix
    docker
    colima #containers in Lima
    hadolint #dockerfile linter
```

### What Apple Container is and how it is normally installed

`container` is distributed by Apple as a signed macOS installer package (a `.pkg` file)
attached to GitHub releases at `https://github.com/apple/container/releases`. Normally you
double-click it and it installs into `/usr/local`. That is exactly what this plan avoids:
installing into `/usr/local` puts files outside Nix's control and outside the declarative
configuration.

A `.pkg` file is an archive in Apple's `xar` format containing, among other things, a
member named `Payload`, which is itself a compressed cpio/tar archive of the files to
install. Both formats can be unpacked without running the installer: `xar -xf <pkg>
Payload` extracts the payload member, and `bsdtar --extract --file Payload --directory
$out` unpacks it. That is precisely how nixpkgs packages it.

Apple Container is a client/server system. The `container` command-line tool talks to a
background process called `container-apiserver`, which macOS's `launchd` service manager
runs as a per-user launch agent. `container system start` registers and starts that agent;
`container system stop` stops and deregisters it; `container system status` reports
whether it is responding. **Nothing works until the service is started**, which is why
this plan does not stop at installing the binary.

The binaries need to know where their own installation lives so they can find helper
executables (`container-core-images`, `container-network-vmnet`,
`container-runtime-linux`). They read this from the `CONTAINER_INSTALL_ROOT` environment
variable. The nixpkgs derivation sets it with a wrapper.

### The nixpkgs derivation this plan copies

For reference, `pkgs/by-name/co/container/package.nix` in nixpkgs-unstable currently reads
as follows. Note the version, `1.1.0`, which is what this plan replaces:

```nix
{
  lib,
  stdenvNoCC,
  fetchurl,
  libarchive,
  xar,
  installShellFiles,
  makeWrapper,
  versionCheckHook,
  nix-update-script,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "container";
  version = "1.1.0";

  src = fetchurl {
    url = "https://github.com/apple/container/releases/download/${finalAttrs.version}/container-${finalAttrs.version}-installer-signed.pkg";
    hash = "sha256-DKHEKiJpwlV++x2CsbOKxVPmo6PaGxF5xDm87h59ZxQ=";
  };

  nativeBuildInputs = [ libarchive xar installShellFiles makeWrapper ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    xar -xf $src Payload
    bsdtar --extract --file Payload --directory $out

    runHook postInstall
  '';

  postInstall = lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
    installShellCompletion --cmd ${finalAttrs.meta.mainProgram} \
      --bash <($out/bin/${finalAttrs.meta.mainProgram} --generate-completion-script bash) \
      --fish <($out/bin/${finalAttrs.meta.mainProgram} --generate-completion-script fish) \
      --zsh <($out/bin/${finalAttrs.meta.mainProgram} --generate-completion-script zsh)
  '';

  postFixup = ''
    wrapProgram $out/bin/container \
      --set-default CONTAINER_INSTALL_ROOT "$out"
    wrapProgram $out/bin/container-apiserver \
      --set-default CONTAINER_INSTALL_ROOT "$out"
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  passthru = { updateScript = nix-update-script { }; };

  meta = {
    description = "Create and run Linux containers using lightweight virtual machines on a Mac";
    homepage = "https://github.com/apple/container";
    changelog = "https://github.com/apple/container/releases/tag/${finalAttrs.version}";
    license = lib.licenses.asl20;
    mainProgram = "container";
    maintainers = with lib.maintainers; [ xiaoxiangmoe Br1ght0ne ];
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
```

`stdenvNoCC` is a build environment without a C compiler, appropriate here because nothing
is compiled — the payload is already-built Apple binaries. `versionCheckHook` is a nixpkgs
helper that runs `$out/bin/<mainProgram> --version` after installation and fails the build
if the output does not contain `version`. `nix-update-script` is nixpkgs' automatic
version-bump helper; it is dropped in the local copy because there is no nixpkgs update
bot operating on this repository.

### The target version and its hash

Upstream's latest release as of 2026-08-08 is **1.2.2**. Its signed installer hash was
prefetched during planning, so no guess-and-fail cycle is needed:

```text
$ nix store prefetch-file --json --hash-type sha256 \
    https://github.com/apple/container/releases/download/1.2.2/container-1.2.2-installer-signed.pkg
{"hash":"sha256-9MfnP3IDclo1Emdt/Z7GxqmKNwk7b9ShsP3PyyJ+IRg=","storePath":"/nix/store/hxx0blmv5i8s1k19plp4lp2y55780r7z-container-1.2.2-installer-signed.pkg"}
```

If a newer release exists by the time you implement this, check
`https://github.com/apple/container/releases` and re-run the prefetch command above with
the new version substituted, then use the resulting `hash` value.

### Platform requirements

Apple Container requires an Apple Silicon Mac and is only supported on macOS 26 or later.
On macOS 15 it runs but user-defined networks do not exist and containers cannot reach
each other, which would make the rest of this MasterPlan impossible. This machine reports:

```text
$ sw_vers
ProductName:		macOS
ProductVersion:		26.5.2
BuildVersion:		25F84
$ uname -m
arm64
```

Both requirements are satisfied. If you are implementing this on a different machine,
verify these first — everything downstream assumes macOS 26+.

### Launchd conventions in this repository

Background services on this machine are per-user launchd agents with labels of the form
`com.shinzui.<name>`, declared through `home-manager`'s `launchd.agents` option. The
conventions are documented at
`/Users/shinzui/Keikaku/dotfiles.nix/docs/local-services.md` and demonstrated in
`/Users/shinzui/Keikaku/dotfiles.nix/home/victorialogs.nix`, which is the file to read
if you need a worked example. Two details from that example matter later in this plan:
agents set `RunAtLoad = true` and `KeepAlive = true`, and each module installs a
`home.activation` hook running *before* `setupLaunchAgents` that stops the old agent and
waits for its process to exit, because `launchctl bootout` returns before the process is
gone and the subsequent `bootstrap` then fails with an I/O error.

Apple Container is a special case: its agent is registered by `container system start`
itself, using the label prefix `com.apple.container.`, not by `home-manager`. So this plan
does not declare a `launchd.agents` entry for `container-apiserver`; it arranges for
`container system start` to be *invoked*. See the Plan of Work for the two candidate
approaches.

### ADR context

Neither `/Users/shinzui/Keikaku/bokuno/redpanda-container/docs/adr/` nor
`/Users/shinzui/Keikaku/dotfiles.nix/docs/adr/` exists, and neither repository has a
`mori.dhall`, so neither has a profile-governed ADR bundle. A Mori registry search for
cross-repository decisions about container runtimes returned nothing:

```bash
$ mori registry concepts --search 'container runtime' --json
[]
```

**No relevant ADR exists.** This plan does not by itself create durable architectural
context worth an ADR — packaging a tool at a pinned version is an ordinary maintenance
decision. The ADR candidates for this initiative belong to plans 3 and 4 and are listed in
the MasterPlan's ADR context section.


## Plan of Work

The work splits into two milestones. The first makes the binary exist; the second makes the
service run. They are separated because the first is verifiable on its own (`nix build`
produces a working `container` executable) and because the second has more than one viable
approach and may need experimentation.

### Milestone 1 — The derivation and its installation

At the end of this milestone, `container` is on `PATH` at version 1.2.2 and reports its
version correctly, but its background service is not yet started automatically.

Create `/Users/shinzui/Keikaku/dotfiles.nix/derivations/apple-container.nix` as a copy of
the nixpkgs derivation reproduced in Context and Orientation above, with four changes:
set `version = "1.2.2"`, set the `src` hash to
`sha256-9MfnP3IDclo1Emdt/Z7GxqmKNwk7b9ShsP3PyyJ+IRg=`, drop the `nix-update-script`
argument and the `passthru.updateScript` attribute it feeds (there is no update bot here),
and add a short comment at the top explaining that this exists because nixpkgs lags
upstream, naming the nixpkgs path it was copied from so a future reader can diff them.

Register it in the overlay. In
`/Users/shinzui/Keikaku/dotfiles.nix/flake-modules/overlays.nix`, inside the `my-packages`
overlay's attribute set — the one that already contains `tmuxai`, `oq`, `uuinfo`, `ck`,
`parqeye`, `hunk`, and the rest — add a `container` attribute calling the new derivation.
Follow the existing style: the entries there use
`final.callPackage (self + "/derivations/<file>") { ... }`. The `self + "/..."` form rather
than a relative path is deliberate in this repository and must be preserved.

Also add `container` to the `packages` attribute set in
`/Users/shinzui/Keikaku/dotfiles.nix/flake-modules/packages.nix` so it can be built and
tested in isolation with `nix build .#container` without a full system rebuild. Note the
comment at the top of that file: it builds its own package set with only the four overlays
its packages need (`pkgs-stable`, `bun2nix`, `my-packages`), which is sufficient here.

Install it for the user. In `/Users/shinzui/Keikaku/dotfiles.nix/home/default.nix`, add
`container` to the `home.packages` list next to the existing `docker` / `colima` /
`hadolint` cluster around line 220, with a short trailing comment identifying it (the file
comments most entries this way). Do **not** remove `colima` or `docker` — the MasterPlan's
Decision Log records that they stay as a fallback.

Verify by building the package alone, then by rebuilding the system.

### Milestone 2 — Starting the background service automatically

At the end of this milestone, logging in leaves `container system status` reporting a
running API server without any manual step, and a container can be run immediately.

The complication described in Context and Orientation is that Apple Container registers
its own launchd agent under `com.apple.container.*` when `container system start` runs. It
is not a `home-manager`-declared agent, so `home-manager`'s usual `launchd.agents` route
does not directly apply. There are two workable approaches; try them in this order.

**Approach A — a `home.activation` hook that runs `container system start` if the service
is not already responding.** This is the simplest and most idempotent option:
`container system status` is a cheap health check, and `container system start` is safe to
call when already running. The hook belongs in a new file
`/Users/shinzui/Keikaku/dotfiles.nix/home/apple-container.nix`, imported from
`/Users/shinzui/Keikaku/dotfiles.nix/home/default.nix` alongside the other `home/*.nix`
imports. Use `lib.hm.dag.entryAfter [ "writeBoundary" ]`, matching
`home.activation.victorialogs-init` in `home/victorialogs.nix`. The weakness of this
approach is that it only runs on `darwin-rebuild switch`, not at login — but because
`container system start` *registers a launchd agent*, and launchd agents persist across
logins once registered, running it once per rebuild is usually enough. Verify that claim
explicitly (see Validation) rather than assuming it.

**Approach B — a `home-manager` launchd agent that runs `container system start` at
login.** If Approach A's registration does not survive a reboot, declare a small
`launchd.agents.apple-container` entry with `RunAtLoad = true` and `KeepAlive = false`
(this is a one-shot starter, not a long-running process, so `KeepAlive` would restart it in
a loop) whose `ProgramArguments` invoke a `pkgs.writeShellScript` wrapper that calls
`container system status` and, if that fails, `container system start
--enable-kernel-install`. Give it the label `com.shinzui.apple-container` per the
repository's convention. The `--enable-kernel-install` flag matters: without it, the first
`container system start` prompts interactively about installing a default Linux kernel,
which would hang a launchd agent forever. Decide the flag's value deliberately and record
it in the Decision Log.

Whichever approach you land on, record which one and why in the Decision Log, and note in
Surprises & Discoveries whether the registration survived a reboot — that fact is not
documented upstream and the next reader will want it.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/dotfiles.nix` unless stated otherwise.

### Step 1 — confirm the platform

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
sw_vers
uname -m
```

Expect `ProductVersion` to be 26.x or later and `uname -m` to print `arm64`. If either is
not the case, stop: the rest of the MasterPlan assumes macOS 26 on Apple Silicon.

### Step 2 — confirm the upstream version and hash

```bash
curl -sfL https://api.github.com/repos/apple/container/releases/latest | jq -r .tag_name
```

Expect `1.2.2` or newer. If newer, get its hash:

```bash
nix store prefetch-file --json --hash-type sha256 \
  https://github.com/apple/container/releases/download/<VERSION>/container-<VERSION>-installer-signed.pkg
```

Expected shape of the output:

```text
{"hash":"sha256-9MfnP3IDclo1Emdt/Z7GxqmKNwk7b9ShsP3PyyJ+IRg=","storePath":"/nix/store/hxx0blmv5i8s1k19plp4lp2y55780r7z-container-1.2.2-installer-signed.pkg"}
```

Use the `hash` field verbatim in the derivation.

### Step 3 — write the derivation

Create `derivations/apple-container.nix`. Start from the nixpkgs source quoted in Context
and Orientation and apply the four changes described in Milestone 1. If you would rather
copy the current upstream file than transcribe it:

```bash
curl -sfL https://raw.githubusercontent.com/NixOS/nixpkgs/nixpkgs-unstable/pkgs/by-name/co/container/package.nix \
  -o derivations/apple-container.nix
```

then edit it. Verify the file you fetched still matches the structure described here
before editing; if nixpkgs has restructured it, prefer the fetched version and adapt.

### Step 4 — register it in the overlay and packages output

Edit `flake-modules/overlays.nix`, adding to the `my-packages` attribute set. Edit
`flake-modules/packages.nix`, adding `container` to the `inherit (pkgs) ...` list.

### Step 5 — build the package alone

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
nix build .#container --print-out-paths
```

Expected: a store path is printed and no error. The build downloads a ~117 MB installer, so
allow time on a cold cache. Then check the binary directly, without installing it:

```bash
./result/bin/container --version
```

Expected output contains `1.2.2`. If `nix build` fails with a hash mismatch, the `got:`
line in the error is the correct hash — but verify it against a fresh prefetch rather than
pasting blindly, since a mismatch can also mean the URL is wrong.

### Step 6 — install it and rebuild the system

Edit `home/default.nix` to add `container` to `home.packages`, then:

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
darwin-rebuild switch --flake .#SungkyungM1X
```

The repository has a `Justfile`; check it first with `just --list` in case there is a
preferred recipe for rebuilding, and use that instead if one exists.

Then, in a **new** shell (so `PATH` is refreshed):

```bash
which container
container --version
```

Expected: a path under `/Users/shinzui/.nix-profile/bin/container` (or the equivalent
home-manager profile path) and version 1.2.2.

### Step 7 — start the service and prove a container runs

```bash
container system start
container system status
```

The first invocation may prompt about installing a default Linux kernel; answer yes. Note
what it asked and whether it wrote anything outside the Nix store — record this in
Surprises & Discoveries, because it affects whether the service can be started
non-interactively from a launchd agent in Milestone 2.

```bash
container run --rm docker.io/library/alpine:latest echo "hello from a Linux VM"
```

Expected output:

```text
hello from a Linux VM
```

This pulls the Alpine image on first run, so expect image-pull progress output before the
echo. Confirm Colima is not involved:

```bash
colima status
```

Expect it to report that Colima is not running. If it *is* running, stop it with
`colima stop` and re-run the `container run` command to prove the two are independent.

### Step 8 — implement automatic startup

Follow Milestone 2. Implement Approach A first:

```bash
cd /Users/shinzui/Keikaku/dotfiles.nix
$EDITOR home/apple-container.nix     # new file
$EDITOR home/default.nix             # add it to the imports list
darwin-rebuild switch --flake .#SungkyungM1X
```

### Step 9 — prove it survives a reboot

```bash
container system stop
sudo reboot
```

After logging back in, in a fresh shell:

```bash
container system status
```

If it reports a running API server with no manual step, Approach A is sufficient. If it
does not, implement Approach B and repeat this step.


## Validation and Acceptance

This plan is complete when all of the following hold on a freshly booted machine, with
Colima stopped.

**The binary is Nix-managed and current.**

```bash
$ which container
/Users/shinzui/.nix-profile/bin/container
$ container --version
container CLI version 1.2.2 ...
```

The path must be under a Nix profile, not `/usr/local/bin`. If it is `/usr/local/bin`,
something installed the `.pkg` outside Nix; uninstall it with
`/usr/local/bin/uninstall-container.sh -k` (the `-k` flag keeps user data) and re-verify.

**The derivation builds reproducibly from a clean state.**

```bash
$ cd /Users/shinzui/Keikaku/dotfiles.nix
$ nix build .#container --rebuild
```

Completes without a hash mismatch.

**The service starts without manual intervention.** After a reboot and login, in a shell
where you have run no `container` command yet:

```bash
$ container system status
```

reports the API server running. Capture the actual output into Surprises & Discoveries the
first time, since the exact format is not documented in this plan.

**A container actually runs, with Colima stopped.**

```bash
$ colima status
# reports not running
$ container run --rm docker.io/library/alpine:latest sh -c 'echo ok; uname -s'
ok
Linux
```

`uname -s` printing `Linux` from a command issued on macOS is the proof that a Linux VM
really booted.

**User-defined networks are available.** This is the capability the rest of the MasterPlan
depends on, and it is the one that would be silently missing on macOS 15:

```bash
$ container network list
NETWORK  STATE    SUBNET
default  running  192.168.64.0/24
```

If `container network list` errors, stop and record it — plan 2 cannot proceed and the
MasterPlan's Console design would need rethinking.

**Nothing else regressed.** `darwin-rebuild switch` completed cleanly and the existing
services still run:

```bash
$ launchctl print gui/$(id -u)/com.shinzui.victorialogs | head -5
```

still reports a loaded agent.


## Idempotence and Recovery

`nix build .#container` is idempotent; repeated runs are cache hits.

`darwin-rebuild switch` is idempotent. If it fails partway, the previous system generation
is untouched and still active; fix the Nix expression and run it again. To roll back to the
previous generation explicitly:

```bash
darwin-rebuild --list-generations
sudo darwin-rebuild --switch-generation <N>
```

`container system start` is safe to run when the service is already running — it reports
the existing state rather than erroring. `container system stop` is likewise safe when
nothing is running. This is what makes the Approach A activation hook safe to run on every
rebuild.

The one genuinely destructive command in this area is
`/usr/local/bin/uninstall-container.sh -d`, which deletes all container user data
(images, volumes, containers). Only the `-k` variant, which keeps user data, should ever
be needed here, and only if a stray `/usr/local` installation exists. Do not run the `-d`
form.

If the derivation builds but `container --version` fails at runtime with a message about
missing helpers, the `CONTAINER_INSTALL_ROOT` wrapper is the suspect: confirm the
`postFixup` block survived the copy and that `$out/bin/container` is a wrapper script (run
`head -5 $(readlink -f ./result/bin/container)` — a `makeWrapper` output starts with
`#!/nix/store/.../bash`).

If the reboot test leaves the service dead and neither approach in Milestone 2 works,
recovery is to accept a manual `container system start` for now, record the failure in
Surprises & Discoveries, and note in this plan that plans 3 and 4 must make the Redpanda
launchd agent wait for the API server rather than assume it. Do not block the MasterPlan on
this.


## Interfaces and Dependencies

**Produced by this plan, consumed by later plans:**

- The nixpkgs overlay attribute `container` in
  `/Users/shinzui/Keikaku/dotfiles.nix/flake-modules/overlays.nix`, resolving to Apple
  Container 1.2.2. This is Integration Point 1 in the MasterPlan. Plan 3
  (`docs/plans/3-build-the-redpanda-container-flake-and-home-manager-module.md`) must not
  hard-code this attribute; it takes a `package` option instead. Plan 4
  (`docs/plans/4-adopt-the-nix-managed-redpanda-across-projects-and-retire-the-colima-path.md`)
  wires the two together.
- The file path `/Users/shinzui/Keikaku/dotfiles.nix/derivations/apple-container.nix`.
- Whatever mechanism ends up starting `container system start` automatically, and the
  recorded fact of whether launchd registration survives a reboot.

**Depended upon by this plan:**

- Nix with flakes, already present (Determinate Nix 3.17.0).
- `nix-darwin`, already configured; the system configuration is named `SungkyungM1X`.
- `home-manager`, integrated through `nix-darwin`.
- Network access to `github.com` for the installer download.

**Nix attributes and functions used:**

- `stdenvNoCC.mkDerivation` from nixpkgs — a builder for packages that compile nothing.
- `fetchurl` — fixed-output fetch, requires the `hash` argument to match exactly.
- `xar` and `libarchive` (for `bsdtar`) — unpack the `.pkg`.
- `makeWrapper` / `wrapProgram` — wrap the binaries to set `CONTAINER_INSTALL_ROOT`.
- `installShellFiles` / `installShellCompletion` — install shell completions.
- `versionCheckHook` — post-install sanity check.
- `lib.hm.dag.entryAfter` and `lib.hm.dag.entryBefore` from `home-manager` — order
  activation scripts; used if Approach A is taken. A worked example is
  `home.activation.victorialogs-init` in
  `/Users/shinzui/Keikaku/dotfiles.nix/home/victorialogs.nix`.
- `pkgs.writeShellScript` — render a shell script into the store; used if Approach B is
  taken.

**Apple Container commands this plan relies on:**

- `container --version` — version reporting.
- `container system start [--enable-kernel-install|--disable-kernel-install]` — start and
  register the API server launch agent.
- `container system stop [--prefix <prefix>]` — stop and deregister it; default launchd
  prefix is `com.apple.container.`.
- `container system status [--format json|table|yaml|toml]` — health check.
- `container network list` — capability probe for macOS 26 user-defined networks.
- `container run --rm <image> <cmd>` — smoke test.
