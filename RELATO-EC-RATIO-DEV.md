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

> A pergunta enviada ao dev (texto exato) não fica duplicada aqui — foi
> mandada diretamente fora do repositório. O essencial pra reproduzir o
> achado já está documentado acima (ambiente, passos, evidência).
