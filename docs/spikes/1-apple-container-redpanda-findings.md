# Findings: Redpanda on Apple Container

Recorded 2026-08-08 on macOS 26.5.2 (build 25F84), arm64, Apple Container 1.2.2,
`rpk` v26.2.1. Produced by the spike described in
`docs/plans/2-spike-prove-redpanda-runs-on-apple-container.md`, under the MasterPlan
`docs/masterplans/1-run-redpanda-locally-on-apple-container-via-nix.md`.

Every transcript below is real output from this machine, not an illustration.


## Conclusions

**Redpanda and Redpanda Console both run on Apple Container, and the design the MasterPlan
assumes is achievable — but not by the mechanism the plan expected.** Four of the ten
experiments turned up behaviour that changes what plan 3 must render.

**1. The internal addressing decision (MasterPlan Integration Point 3).** The broker
advertises the fixed container name `redpanda-0`, and Console resolves that name through a
**bind-mounted `/etc/hosts` file** generated on the host at start time from the broker's
discovered IP address. Written out:

```text
--advertise-kafka-addr internal://redpanda-0:9092,external://127.0.0.1:9092
```

with Console started as:

```text
-v <generated-hosts-file>:/etc/hosts
```

This was **not** one of the three candidates the plan listed. All three of those failed:
the bare container name does not resolve, the name qualified with a DNS domain does not
resolve even after `sudo container system dns create`, and a raw IP address cannot be used
because the broker's advertised address is fixed at `container run` time — before the
container has an IP — and because IPs are not stable across restarts. The `/etc/hosts`
mount is what makes a *stable name* work without DNS.

**2. No `sudo` step is required, and adding one would not help.** The plan asked
specifically whether `sudo container system dns create <domain>` is needed so that plan 4
could put it in the runbook. The answer is no: it was tested and does not enable
container-to-container resolution at all. **Plan 4 must not include this step.** The domain
created during this spike (`test`) can be removed with `sudo container system dns delete test`.

**3. The named volume must be chowned to `101:101` before first use.** The Redpanda image
runs as `uid=101(redpanda)`, but a freshly created Apple Container volume mounts root-owned,
which masks the image's correctly-owned data directory and makes the broker die on startup.
Plan 3 must chown the volume as part of creating it.

**4. The image must be pulled and run with an explicit `--platform linux/arm64`.** Without
it, Apple Container selected the `linux/amd64` variant of the multi-arch Redpanda image on
this arm64 machine, which would run the broker under emulation.

Two further operational constraints plan 3 must design around:

**5. Container-to-container networking degrades and is repaired by restarting the runtime.**
It worked, then silently stopped working (every container-to-container packet dropped),
then was fully restored by `container system stop && container system start`. Anything that
depends on Console reaching the broker must verify connectivity rather than assume it.

**6. Console must be restarted whenever the broker restarts.** The broker gets a new IP on
every restart, which makes the generated `/etc/hosts` file stale, and Console does not
recover on its own.


## Experiment A — Images pull

Question: can Apple Container pull the Redpanda images?

**Verdict: yes, but not from the documented registry, and not at the right architecture by
default.**

`docker.redpanda.com` rate-limited every attempt, across several minutes and multiple
retries:

```text
$ container image pull docker.redpanda.com/redpandadata/redpanda:v26.2.1
Error: HTTP request to https://docker.redpanda.com/v2/redpandadata/redpanda/manifests/v26.2.1
failed with response: 429 Too Many Requests. Reason: Unknown
$ echo $?
1
```

The exit code is worth noting: `container image pull` does exit non-zero on failure, so a
script can detect this. (An earlier reading of exit `0` in this spike was an artifact of
piping the command into `tail`, which masked the real status — a trap worth avoiding in
plan 3's scripts.)

Docker Hub carries the same images and worked:

```text
$ container image pull docker.io/redpandadata/redpanda:v26.2.1
[2/2] Unpacking image for platform linux/amd64 100% (5,503 of 5,503 entries, 346.6/346.6 MB) [12s]
```

Note `linux/amd64` — on an arm64 Mac. The image is multi-arch and Apple Container chose the
wrong variant. Forcing the platform works:

```text
$ container image pull --platform linux/arm64 docker.io/redpandadata/redpanda:v26.2.1
$ echo $?
0
```

`container run` also accepts `--platform`, plus `-a/--arch` and `--os`, and honours the
`CONTAINER_DEFAULT_PLATFORM` environment variable. Containers started with
`--platform linux/arm64` report `arm64` in `container list`.

For plan 3: pull from `docker.io/redpandadata/...` with an explicit
`--platform linux/arm64`, and treat `docker.redpanda.com` as an unreliable source.


## Experiment B — Two containers on a user-defined network can reach each other

Question: does container-to-container networking work at all?

**Verdict: yes, initially — but see Experiment B2 below, which is the important one.**

```text
$ container network create spike-redpanda
spike-redpanda
$ container network list
NETWORK         SUBNET
default         192.168.64.0/24
spike-redpanda  192.168.65.0/24
```

Two Alpine containers on that network, at `192.168.65.2` and `192.168.65.3`:

```text
$ container exec spike-b ping -c 2 192.168.65.2
64 bytes from 192.168.65.2: seq=1 ttl=64 time=1.236 ms
--- 192.168.65.2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

Routing by IP works. `container network list` has columns `NETWORK  SUBNET` — there is **no
`STATE` column**, contrary to what plan 1's validation section predicted.


## Experiment B2 — Networking degrades, and a runtime restart repairs it

This experiment was not in the plan. It exists because connectivity that had demonstrably
worked stopped working partway through the spike.

**Verdict: container-to-container networking is not durable. `container system stop &&
container system start` restores it.**

After creating a DNS domain and restarting the runtime, every container-to-container packet
was dropped — including to containers that had been reachable minutes earlier, and
including a freshly created pair:

```text
$ container run --rm --network spike-redpanda alpine ping -c 2 192.168.65.5
--- 192.168.65.5 ping statistics ---
2 packets transmitted, 0 packets received, 100% packet loss
```

This was first suspected to be caused by publishing ports, since the broker published four
and the working Alpine pair published none. That hypothesis was tested directly and
**disproved** — with networking in the degraded state, a container with a published port and
a container without one were equally unreachable:

```text
to NO-port container:
--- 192.168.65.9 ping statistics ---
2 packets transmitted, 0 packets received, 100% packet loss
to WITH-port container:
--- 192.168.65.10 ping statistics ---
2 packets transmitted, 0 packets received, 100% packet loss
```

Restarting the runtime fixed it completely:

```text
$ container system stop && container system start --enable-kernel-install
$ container run --rm --network spike-redpanda alpine ping -c 2 192.168.65.2
--- 192.168.65.2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

and immediately afterwards a TCP probe to the broker succeeded where it had failed:

```text
TCP 9092 OPEN
```

The MasterPlan already recorded community reports of DNS breaking after host sleep/wake and
recovering on a runtime restart. This is the same class of fault, observed without any sleep
— so plan 3 should not treat it as a rare edge case. `redpanda-up` and the launchd agent
should verify that Console can actually reach the broker, and a documented remedy of
`container system stop && container system start` belongs in plan 4's runbook.


## Experiment C — Which name string resolves

Question: what exact string does one container use to address another?

**Verdict: none of them. Container-to-container name resolution does not work on Apple
Container 1.2.2, with or without a registered DNS domain.**

This is the spike's most consequential finding. Every candidate was tested.

The bare name, on a user-defined network:

```text
$ container exec spike-b getent hosts spike-a
$ echo $?
2
$ container exec spike-b ping -c 2 spike-a
ping: bad address 'spike-a'
```

The container does have a nameserver, and it is the network's gateway:

```text
$ container exec spike-b cat /etc/resolv.conf
nameserver 192.168.65.1
```

`--dns-domain test` alone sets the domain but changes nothing:

```text
$ container exec spike-c cat /etc/resolv.conf
nameserver 192.168.65.1
domain test
$ container exec spike-c getent hosts spike-a.test   # exit 2
$ container exec spike-c getent hosts spike-a        # exit 2
```

A registered DNS domain does not help either. `sudo container system dns create test` was
run, and confirmed registered:

```text
$ container system dns list
DOMAIN
test
```

Resolution still failed, and the embedded resolver answered authoritatively that the name
does not exist:

```text
$ container exec spike-b nslookup spike-a.test
Server:		192.168.65.1
Address:	192.168.65.1:53
** server can't find spike-a.test: NXDOMAIN
```

This was retested after restarting the runtime *and* recreating both containers with
`--dns-domain test` so that neither predated the domain. Still `exit 2` for both the
qualified and bare forms.

The reason is visible in what `container system dns create` actually writes. It is a
**macOS-side** resolver entry, pointing at a DNS service on the host — not a mechanism for
registering container records:

```text
$ cat /etc/resolver/containerization.test
domain test
search test
nameserver 127.0.0.1
port 2053
```

Containers were not resolvable from macOS through it either, so nothing appears to populate
that zone with container names in this version.

Two further avenues were closed off:

- Containers on the **default** network also cannot resolve each other by name, so this is
  not a user-defined-network limitation.
- There is no way to set a system default DNS domain: `container system property` has only a
  `list` subcommand, and its `[dns]` section is empty.

**The workaround that does work** is to bind-mount a hosts file from macOS over
`/etc/hosts` in the consuming container. It resolves correctly and, critically, works for a
**non-root** user, so Console does not have to be run as root:

```text
$ cat hosts
127.0.0.1	localhost
192.168.65.5	spike-redpanda-0

$ container run --rm --network spike-redpanda --user 100 -v "$PWD/hosts":/etc/hosts alpine \
    sh -c 'id; getent hosts spike-redpanda-0'
uid=100 gid=0(root) groups=0(root)
192.168.65.5      spike-redpanda-0  spike-redpanda-0
```

This matters because the Console image runs as `uid=100(redpandaconsole)` and so could not
have written `/etc/hosts` itself:

```text
$ container run --rm --entrypoint /bin/sh docker.io/redpandadata/console:v3.9.0 -c 'id'
uid=100(redpandaconsole) gid=101(redpandaconsole) groups=101(redpandaconsole)
```

Mounting the file also avoids overriding the image's entrypoint, which is what both the
Redpanda quickstart and `rpk container start` resort to.


## Experiment D — Named volumes persist across container deletion

Question: does a named volume outlive the container that wrote to it?

**Verdict: yes.**

```text
$ container volume create spike-redpanda-0-data
spike-redpanda-0-data

$ container run --rm -v spike-redpanda-0-data:/data alpine \
    sh -c 'echo "written-by-first-container" > /data/marker.txt; cat /data/marker.txt'
written-by-first-container

$ container run --rm -v spike-redpanda-0-data:/data alpine cat /data/marker.txt
written-by-first-container
```

The first container was removed by `--rm` before the second ran, so the volume — not a
container layer — held the data.


## Experiment E — A Redpanda broker starts

Question: does Redpanda boot in `dev-container` mode with a named volume and stay up?

**Verdict: yes, but only after the volume is chowned to `101:101`.**

The first attempt started and immediately exited. `container list --all` showed `stopped`,
and the application log gave the reason:

```text
ERROR 2026-08-09 02:28:08,887 [shard 0:main] main - application.cc:384 - Failure during startup:
std::__1::__fs::filesystem::filesystem_error (error system:13, filesystem error: mkdir failed:
Permission denied ["/var/lib/redpanda/data/crash_reports"])
```

The cause is an ownership mismatch. The image runs as uid 101 and ships its data directory
owned by 101, but an Apple Container named volume mounts root-owned and masks it:

```text
$ container run --rm --entrypoint /bin/sh docker.io/redpandadata/redpanda:v26.2.1 \
    -c 'id; ls -ldn /var/lib/redpanda/data'
uid=101(redpanda) gid=101(redpanda) groups=101(redpanda)
drwxr-xr-x 2 101 101 4096 Apr 18  2019 /var/lib/redpanda/data

$ container run --rm -v spike-redpanda-0-data:/data alpine ls -ldn /data
drwxr-xr-x    3 0        0             4096 Aug  9 02:27 /data
```

One chown fixes it permanently, since the volume persists:

```text
$ container run --rm -v spike-redpanda-0-data:/data alpine \
    sh -c 'chown -R 101:101 /data && ls -ldn /data'
drwxr-xr-x    3 101      101           4096 Aug  9 02:27 /data
```

After that the broker runs. The full working invocation, with the spike's names:

```bash
container run -d \
  --name spike-redpanda-0 \
  --network spike-redpanda \
  --platform linux/arm64 \
  -l dev.shinzui.spike=redpanda \
  -l dev.shinzui.spike.role=broker \
  -v spike-redpanda-0-data:/var/lib/redpanda/data \
  -c 2 -m 2G \
  -p 127.0.0.1:9092:19092 \
  -p 127.0.0.1:9644:9644 \
  -p 127.0.0.1:8081:18081 \
  -p 127.0.0.1:8082:18082 \
  docker.io/redpandadata/redpanda:v26.2.1 \
  redpanda start \
    --node-id 0 \
    --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092 \
    --advertise-kafka-addr internal://spike-redpanda-0:9092,external://127.0.0.1:9092 \
    --pandaproxy-addr internal://0.0.0.0:8082,external://0.0.0.0:18082 \
    --advertise-pandaproxy-addr internal://spike-redpanda-0:8082,external://127.0.0.1:8082 \
    --schema-registry-addr internal://0.0.0.0:8081,external://0.0.0.0:18081 \
    --rpc-addr 0.0.0.0:33145 \
    --advertise-rpc-addr spike-redpanda-0:33145 \
    --mode dev-container \
    --smp 1 \
    --default-log-level=info
```

Binding `--rpc-addr` to `0.0.0.0` while advertising the name was accepted; Redpanda did not
object, and with one broker nothing connects over RPC anyway.

**Readiness.** `/v1/status/ready` on the Admin API works and is the check plan 3 should
poll. It returned ready on the first poll, roughly one second after the container reached
running state:

```text
$ curl -s http://127.0.0.1:9644/v1/status/ready
{"status":"ready"}
```

Startup is fast — consistently "ready after 1s" once the container is up. A poll loop with a
60-second ceiling is comfortable.


## Experiment F — Kafka works from macOS

Question: can `rpk` on macOS produce and consume through the published port?

**Verdict: yes. This is the MasterPlan's headline acceptance and it passes.**

```text
$ rpk cluster info --brokers 127.0.0.1:9092
CLUSTER
=======
redpanda.461b91b3-dbe3-4f3b-9bb5-dfb50280faf6

BROKERS
=======
ID    HOST       PORT
0*    127.0.0.1  9092

$ rpk topic create spike-test --brokers 127.0.0.1:9092
TOPIC       STATUS
spike-test  OK

$ echo "hello" | rpk topic produce spike-test --brokers 127.0.0.1:9092
Produced to partition 0 at offset 0 with timestamp 1786242553203.

$ rpk topic consume spike-test -n 1 --brokers 127.0.0.1:9092
{
  "topic": "spike-test",
  "value": "hello",
  "timestamp": 1786242553203,
  "partition": 0,
  "offset": 0
}
```

The broker correctly advertises `127.0.0.1:9092` to macOS clients — `rpk cluster info`
reports host `127.0.0.1`, which is what makes the follow-up connections work.


## Experiment G — Admin API, Schema Registry, and HTTP Proxy

Question: do the other three published services respond?

**Verdict: all three work.**

```text
$ curl -s http://127.0.0.1:9644/v1/status/ready
{"status":"ready"}

$ curl -s http://127.0.0.1:8081/subjects
[]

$ curl -s http://127.0.0.1:8082/topics
["spike-test","_schemas"]
```

All four host ports are bound by the runtime, to loopback only as requested:

```text
$ lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(9092|9644|8081|8082)\b'
container 127.0.0.1:9092
container 127.0.0.1:9644
container 127.0.0.1:8081
container 127.0.0.1:8082
```

The Admin API also confirms the broker registered its internal RPC address as the name
rather than an IP, which is consistent with the addressing decision:

```text
$ curl -s http://127.0.0.1:9644/v1/brokers
[{"node_id": 0, "num_cores": 1, "internal_rpc_address": "spike-redpanda-0",
  "internal_rpc_port": 33145, "membership_status": "active", "is_alive": true, ...}]
```


## Experiment H — Console reaches the broker

Question: can Console, in its own container, reach the broker over the container network
using the internal advertised address?

**Verdict: yes, via the bind-mounted `/etc/hosts` file from Experiment C.**

Console is configured by a file whose path comes from `CONFIG_FILEPATH`. Mounting both the
config and the hosts file avoids overriding the entrypoint entirely:

```yaml
kafka:
  brokers: ["spike-redpanda-0:9092"]
schemaRegistry:
  enabled: true
  urls: ["http://spike-redpanda-0:8081"]
redpanda:
  adminApi:
    enabled: true
    urls: ["http://spike-redpanda-0:9644"]
```

```bash
container run -d \
  --name spike-redpanda-console \
  --network spike-redpanda \
  --platform linux/arm64 \
  -p 127.0.0.1:8080:8080 \
  -e CONFIG_FILEPATH=/etc/console/config.yaml \
  -v <generated-hosts-file>:/etc/hosts \
  -v <console-config.yaml>:/etc/console/config.yaml \
  docker.io/redpandadata/console:v3.9.0
```

Console connected to both the Admin API and the Kafka API:

```text
{"level":"INFO","msg":"successfully loaded Redpanda Enterprise license",
 "license_type":"free_trial","license_source":"Redpanda cluster"}
{"level":"INFO","msg":"started Redpanda Console","version":"v3.9.0"}
{"level":"INFO","msg":"successfully connected to kafka cluster",
 "advertised_broker_count":1,"topic_count":2,"controller_id":0}
{"level":"INFO","msg":"Server listening on address","address":"[::]:8080","port":8080}
```

```text
$ curl -sf http://127.0.0.1:8080 -o /dev/null -w 'HTTP %{http_code}\n'
HTTP 200

$ curl -s http://127.0.0.1:8080/api/topics | jq -r '.topics[].topicName'
_schemas
spike-test
```

Console listing `spike-test` is the acceptance for this experiment: it proves Console
reached the broker over the container network on the `internal` listener while `rpk` was
simultaneously using the `external` one. The internal/external listener split works.


## Experiment H2 — Console breaks when the broker's IP changes

This experiment was not in the plan. It follows from the addressing decision and is an
operational constraint plan 3 must handle.

**Verdict: the broker gets a new IP on every restart, which makes the generated hosts file
stale, and Console does not recover on its own.**

IPs are not stable. Across this spike a single broker container held `.5`, then `.4`, then
`.8`, and an Alpine container moved from `.2` to `.5` across one stop/start. After
recreating the broker while leaving Console running:

```text
$ cat hosts                       # what Console has mounted
192.168.65.4	spike-redpanda-0
$ container inspect spike-redpanda-0 | jq -r '.[0].status.networks[0].ipv4Address'
192.168.65.8/24
```

Console failed accordingly, and returned HTTP 500 from its API:

```text
{"level":"WARN","msg":"unable to open connection to broker","addr":"spike-redpanda-0:9092",
 "err":"dial tcp 192.168.65.4:9092: connect: no route to host"}
{"level":"ERROR","msg":"Sending REST error","route":"/api/topics","status_code":500,
 "public_error":"Could not list topics from Kafka cluster"}
```

The remediation was verified: regenerate the hosts file from the broker's current IP and
restart Console.

```text
regenerated hosts -> 192.168.65.8
$ curl -s http://127.0.0.1:8080/api/topics | jq -r '.topics[].topicName'
_schemas
spike-test
$ curl -sf http://127.0.0.1:8080 -o /dev/null -w 'HTTP %{http_code}\n'
HTTP 200
```

For plan 3: `redpanda-up` must start the broker first, wait for it to be ready, read its IP,
write the hosts file, and only then start Console. Restarting the broker alone is not a
supported operation — anything that restarts the broker must also restart Console.


## Experiment I — Data survives stop/start and full deletion

Question: do topics and messages survive restarts?

**Verdict: yes, in both the weak and the strong form.**

Weak form, `container stop` then `container start`:

```text
ready after 1s
NAME        PARTITIONS  REPLICAS
_schemas    1           1
spike-test  1           1
{"value":"hello","offset":0}
```

Strong form — `container stop`, `container delete`, then a fresh `container run` against the
same volume. This is the one that proves the volume rather than the container's writable
layer holds the state, and it is the arrangement `rpk container start` never used:

```text
broker containers remaining: 0
ready after 1s
NAME        PARTITIONS  REPLICAS
_schemas    1           1
spike-test  1           1
{"value":"hello","offset":0}
```

`redpanda-down` followed by `redpanda-up` will therefore preserve topics and messages.


## Experiment J — Labels and JSON output

Question: can `redpanda-status` and `redpanda-purge` find their resources reliably?

**Verdict: yes, with `jq`. There is no server-side label filtering.**

`container inspect` and `container list --format json` return objects with three top-level
keys: `configuration`, `id`, `status`. The paths plan 3 needs:

```text
name    .configuration.id
state   .status.state                          # "running" | "stopped"
IP      .status.networks[0].ipv4Address        # includes /24 suffix — strip it
host    .status.networks[0].hostname
network .status.networks[0].network
image   .configuration.image.reference
labels  .configuration.labels                  # object of key -> value
started .status.startedDate
```

Labels set with `-l` do come back intact:

```text
$ container inspect spike-redpanda-0 | jq -r '.[0].configuration.labels'
{
  "dev.shinzui.spike": "redpanda",
  "dev.shinzui.spike.role": "broker"
}
```

Extracting the IP for the hosts file, which is the exact expression plan 3 needs:

```bash
container inspect redpanda-0 | jq -r '.[0].status.networks[0].ipv4Address' | cut -d/ -f1
```

`container list --help` advertises no `--filter` or label-selection option, so status and
purge scripts must list everything and filter on `.configuration.labels` in `jq`.


## Answers to the plan's acceptance questions

1. **Which string does one container use to address another?** None resolve. Use the fixed
   name `redpanda-0` in the advertised address, and make it resolvable in the consuming
   container with a bind-mounted `/etc/hosts` file built from the broker's discovered IP.
2. **Is a `sudo container system dns create <domain>` step required?** No — and it does not
   work. Plan 4 must not put it in the runbook.
3. **Does a named volume preserve topics across container deletion?** Yes, provided it is
   chowned to `101:101` before first use.
4. **Which readiness check works, and how long does startup take?**
   `curl -sf http://127.0.0.1:9644/v1/status/ready`, returning `{"status":"ready"}`,
   approximately one second after the container is running.
5. **What is the working Console configuration?** The YAML and `container run` invocation in
   Experiment H, with `/etc/hosts` and the config file both bind-mounted.
6. **What is the `jq` path to each field a status script needs?** Listed in Experiment J.
7. **Are the five host ports free and did publishing work?** Yes for all five; nothing else
   on this machine listens on 9092, 9644, 8081, 8082, or 8080.
8. **What went wrong that the plan did not anticipate?** The registry rate limit and wrong
   default architecture (A), the total absence of container name resolution (C), the volume
   ownership mismatch (E), networking degrading until a runtime restart (B2), and Console
   breaking on broker IP change (H2).
