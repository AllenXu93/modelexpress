# MX v2 benchmarks

Transport-layer benchmarks for ModelExpress v2 + `MxWeightTransferEngine`.

## What's measured

- **Cold-start join latency** for receivers in an elastic deployment
- **Per-receive RDMA bandwidth** (GB/s) and tensor count
- **Discovery (control-plane) vs RDMA (data-plane)** latency split
- **Compile-target filter** behavior (accept / reject / back-compat)
- **Trainer egress savings under tree fan-out** (pipeline replication)

These exercise the same v2 fat-client code paths vLLM hits through
`MxWeightTransferEngine`, so the numbers are representative.

## Quick CPU smoke (no MX server / NIXL / GPUs needed)

```bash
python bench_elastic_scaling.py --mode=cpu --scenario=tree_fanout \
    --num-receivers=4 --steps=3
```

Useful for orchestrator-logic CI and developing scenarios offline.

## Live runs (MX server + GPU + NIXL required)

Single host, one trainer + 3 receivers, two refit cycles:

```bash
export MX_SERVER_URL=modelexpress-server.kavin.svc.cluster.local:8001
python bench_elastic_scaling.py \
    --scenario=elastic_scale \
    --num-receivers=3 --steps=2 \
    --num-tensors=64 --tensor-bytes=$((8*1024*1024)) \
    --join-interval=2.0 --step-interval=3.0 \
    --output=elastic.json
```

Compile-target safety net + back-compat demo (one trainer, three
receivers with different filters):

```bash
python bench_elastic_scaling.py \
    --scenario=compile_target \
    --trainer-compile-target=cutlass_fp8 \
    --num-tensors=16 --tensor-bytes=$((4*1024*1024)) \
    --output=compile_target.json
```

Expected: `recv-match` accepts, `recv-mismatch` is rejected at
discovery (no RDMA cycles spent), `recv-no-filter` accepts (back-compat).

Tree fan-out (newcomers pull from earlier receivers, not the trainer):

```bash
python bench_elastic_scaling.py \
    --scenario=tree_fanout \
    --num-receivers=4 --steps=3 \
    --join-interval=2.0 --step-interval=4.0 \
    --num-tensors=64 --tensor-bytes=$((8*1024*1024)) \
    --output=tree_fanout.json
```

Expected: `fanout_factor > 1.0` — total bytes delivered exceeds trainer
egress because receivers 2..N pulled from already-loaded peers.

## Cluster mode (Kubernetes — kavin namespace)

The same script runs unchanged inside any pod that can resolve the MX
server. The recommended pattern for the cluster is a single
benchmark job that pins to a known set of GB200 nodes:

```yaml
# benchmarks/k8s/bench-elastic.yaml — to be added in a follow-up commit
apiVersion: batch/v1
kind: Job
metadata:
  name: mx-bench-elastic
  namespace: kavin
spec:
  template:
    spec:
      containers:
        - name: bench
          image: <prime-rl image with this branch>
          command: [
            "python",
            "/app/.venv/lib/python3.12/site-packages/modelexpress/benchmarks/bench_elastic_scaling.py",
            "--scenario=elastic_scale",
            "--num-receivers=4",
            "--steps=3",
            "--output=/results/elastic.json"
          ]
```

## Output schema

`--output results.json` produces a machine-readable document:

```json
{
  "scenario": "elastic_scale",
  "config": { ... CLI args ... },
  "started_at": 1748567890.12,
  "finished_at": 1748567945.41,
  "wall_seconds": 55.29,
  "trainer": {
    "worker_id": "bench-trainer-r0",
    "mx_source_id": "...",
    "published_versions": [1, 2, 3],
    "compile_target": "cutlass_fp8",
    "total_published_bytes": 1342177280
  },
  "receivers": [
    {
      "receiver_id": "recv-0",
      "worker_rank": 0,
      "join_latency_seconds": 0.41,
      "compile_target_filter": null,
      "cycles": [
        {
          "version": 1,
          "bytes_received": 134217728,
          "rdma_seconds": 0.082,
          "bandwidth_gbps": 13.1,
          "discovery_seconds": 0.014,
          "source_worker_rank": 0
        }
      ]
    }
  ],
  "derived": {
    "trainer_egress_bytes": 402653184,
    "total_delivered_bytes": 1207959552,
    "scenario_specific": {
      "fanout_factor": 3.0,
      "trainer_egress_mb": 402.7,
      "total_delivered_mb": 1208.0
    }
  }
}
```

## Caveats

- The harness expects a working MX server reachable at
  `--mx-server-url`. Boot one in your namespace before running.
- "Live" mode requires NIXL + CUDA; `--mode=cpu` is the fallback.
- The trainer subprocess holds the source alive for a generous tail
  past its last publish so late receivers can still discover it. If
  you need long-running publishes, run the trainer separately and
  point receivers at it via `--num-receivers=N --steps=0` (skips
  trainer launch). (Roadmap.)
