# Report: `ec.encode` (weed shell) does not honor the configured EC ratio

## Environment

- SeaweedFS Enterprise, `weed version` → `8000GB 4.45-enterprise` (binary `weed-enterprise-linux_amd64_large_disk.tar.gz`, `seaweedfs/artifactory` releases, tag `4.45.1`).
- Default enterprise trial license (25TB), no custom license file.
- Cluster: 3 masters (raft) + filer (Postgres store) each, 1 standalone `weed s3`, 7 volume nodes.
- `ec.config -get` confirmed **`Global Default EC Ratio: 5+2`** before every test below.

## Summary

`ec.config -set -dataShards=5 -parityShards=2` updates what `ec.config -get` reports, and is saved to `/etc/seaweedfs/ec.conf` on the filer ("✓ Configuration saved to filer at /etc/seaweedfs/ec.conf"). However, running `ec.encode` manually via `weed shell` still physically writes the **classic 14-shard (10+4) layout** — `.ec00` through `.ec13` — instead of 7 shards. Confirmed 3 times independently, at increasing data sizes, ruling out a small-file/padding artifact.

## Steps to reproduce

```
# 1. Set the ratio and confirm it's active
weed shell -master=localhost:9333
> ec.config -set -dataShards=5 -parityShards=2
Global default EC ratio set to 5+2
✓ Configuration saved to filer at /etc/seaweedfs/ec.conf
> ec.config -get
Global Default EC Ratio: 5+2

# 2. Upload a normal (non-EC) volume with real data (any size — see results below)

# 3. Force-encode it (bypassing the fullness/quiet-time scheduler gates,
#    since we're testing manually rather than waiting for the automatic
#    admin+worker maintenance scan):
> lock
> ec.encode -volumeId=<id> -quietFor=0s -fullPercent=0
> unlock

# 4. Count the actual .ecNN shard files written to the volume servers'
#    data directories for that volume id.
```

## Results (3 independent runs)

| Run | Source data | Shard files found | Shard size (each) | Expected for 5+2 |
|---|---|---|---|---|
| 1 | 5 volumes, 39KB–1.18MB (poc-bucket) | **14 per volume** (`.ec00`–`.ec13`) | 1,048,576 bytes (1 MiB) uniform | 7 per volume |
| 2 | Fresh 50-byte file, isolated collection, ratio confirmed set *before* upload | **14** (`.ec00`–`.ec13`) | 1,048,576 bytes (1 MiB) uniform | 7 |
| 3 | Single 30MB needle (uploaded directly to a volume server, bypassing filer chunking, to rule out multi-chunk artifacts) | **14** (`.ec00`–`.ec13`) | 4,194,304 bytes (4 MiB) uniform | 7 |

Physical disk usage in all 3 runs matched `bucket_physical_size_bytes` almost exactly (confirmed via `du`/direct file listing on every volume node), so this isn't a metrics-reporting bug — the encoder itself is writing 14 real shard files.

Data integrity was verified after EC in run 3 (MD5 identical before/after, read back via the master-resolved file id).

## Run 4 — ruling out a topology-count coincidence

After runs 1-3, a reasonable alternate hypothesis came up: what if 14 isn't hardcoded, but happens to match some property of *that* cluster (e.g. total volume-server process count)? At the time of runs 1-3 the cluster had 14 `weed volume` **processes** spread across 7 racks (2 processes/rack, sharing 1 disk each — an artifact of the lab, not of SeaweedFS).

We since rebuilt the same cluster with **1 `weed volume` process per rack, each process owning 8 independent disks** (so now genuinely 7 volume-server processes, 7 racks, not 14 of anything). Re-ran the identical manual `ec.encode` reproduction on this new topology:

```
mount 5.[0 1 2 3 4 5 6 7 8 9 10 11 12 13]
```

Still exactly **14 shards** (`.ec00`-`.ec13`) — unchanged despite the process/rack count changing from 14 to 7. This rules out any dependency on the number of available volume servers or racks: 10+4 is emitted regardless of cluster size. With only 7 real placement targets for 14 shards, the placement logic just doubled/tripled up on some of them:

| Node | Shards | Count |
|---|---|---|
| .51 | 0, 6, 10 | 3 |
| .52 | 8, 9, 13 | 3 |
| .53 | 1, 7, 11 | 3 |
| .54 | 2, 12 | 2 |
| .55 | 3 | 1 |
| .56 | 4 | 1 |
| .57 | 5 | 1 |

## Working theory

Given the automatic maintenance-scanner path (`detection.go`, see our separate report `RELATO-EC-AUTO-STUCK-DEV.md`) *does* correctly read `ec.config` and plan `dataShards+parityShards` destinations, while the manual `weed shell ec.encode` command does not (confirmed across 4 runs, 2 different cluster topologies), our best guess is that this build has **two independent EC-encoding code paths**: a newer one wired to the configurable ratio (used by the automatic scanner), and an older/legacy one still hardcoded to the classic OSS 10+4 split (used by the manual shell command). Not a topology artifact — a real inconsistency between two code paths in the same binary.

## Bonus: the Admin UI surfaces the same inconsistency, and mislabels shards on top of it

The `weed admin` dashboard's volume detail page (Volume Information / Shard Distribution panels) for a volume produced by this bug shows the mismatch plainly:

- **EC Config: `5 data, 2 parity`** — the panel reads this straight from the cluster's `ec.config` (5+2), not from what's actually on disk.
- **Status: `Complete (14/7 shards)`** — the UI's own text admits the discrepancy: it expected 7 (per `ec.config`) and found 14 on disk, and still reports the volume as "Complete" since 14 ≥ 7.
- **Shard badges: `D00`-`D04` (blue, "Data") + `P05`-`P13` (yellow, "Parity")** — the UI colors the first `dataShards` (5, from `ec.config`) shards as data and everything else as parity. Since the volume actually holds the classic 10+4 layout, shards `05`-`09` are **real data shards**, not parity — the UI's labeling logic trusts the configured ratio instead of the shard contents.

This isn't a new bug — it's the same root cause (`ec.encode` ignoring `ec.config`) becoming visible in the dashboard, and it's a handy way to spot an affected volume at a glance: any volume showing `N/7` (N > 7) in its Status badge, or 14 shard badges instead of 7, has the classic 10+4 layout regardless of what `EC Config` says above it.

> A pergunta enviada ao dev (texto exato) não fica duplicada aqui — foi
> mandada diretamente fora do repositório. O essencial pra reproduzir o
> achado já está documentado acima (ambiente, passos, evidência).
