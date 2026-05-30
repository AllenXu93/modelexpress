#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# End-to-end driver for the MX v2 transport-layer benchmark on the
# kavin namespace. From this checkout, in ~10 minutes:
#
#     ./run_cluster_bench.sh           # package + apply + wait + collect
#     ./run_cluster_bench.sh --watch   # also tail pod logs live
#
# How it works:
#   1. Packages the current branch's modelexpress/ + benchmarks/ python
#      files into two ConfigMaps (mx-v2-modelexpress + mx-v2-benchmarks)
#   2. Applies bench-elastic.yaml — a Job that mounts those CMs as a
#      PYTHONPATH overlay on top of the prime-rl-mx-on-nixl:v0.5.2
#      image and runs all three scenarios
#   3. Waits for completion, kubectl-cp's /results/ out to a local dir,
#      and prints a summary
#
# Requires: kubectl pointed at the cluster, kavin namespace, GPU quota
# (4 GPUs per Job pod), modelexpress-server reachable in-cluster.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/k8s/bench-elastic.yaml"
NS="kavin"
JOB="mx-bench-elastic"

WATCH=""
if [[ "${1:-}" == "--watch" ]]; then
    WATCH=1
fi

PYTHON_ROOT="$(cd "$HERE/.." && pwd)"   # modelexpress_client/python/

echo "[1/6] Cleaning up any prior bench Job + ConfigMaps..."
kubectl -n "$NS" delete job "$JOB" --ignore-not-found=true --wait=true
kubectl -n "$NS" delete configmap mx-v2-files mx-v2-modelexpress mx-v2-benchmarks --ignore-not-found=true

echo "[2/6] Packaging v2 overlay into ConfigMaps..."
# Strategy: overlay only the files we changed on top of the image's
# installed modelexpress. The pod's startup script copies the image's
# /app/.venv/.../modelexpress/ to /tmp/mx_overlay/modelexpress/, then
# overwrites the listed files with our v2 versions. PYTHONPATH then
# points at /tmp/mx_overlay/ so Python loads our overlaid package.
#
# This avoids fighting ConfigMap's flat (no-subdir) layout and keeps
# the overlay tiny (< 100KB).
#
# Files I modified/added in this branch:
#   - vllm_weight_transfer.py    (new)
#   - nemo_rl_v2.py              (modified — receive_from_scratch, discovery timing)
#   - refit_receiver.py          (modified — TransferStats)
#   - shape_descriptors.py       (modified — compile_target fields, but only if
#                                  it's already a v2 file in the image; safe to copy)
#   - __init__.py                (modified — re-exports)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

mkdir -p "$TMPDIR/v2_files" "$TMPDIR/benchmarks"

# The files our patch touches. We deliberately do NOT include
# __init__.py — the image's v0.5.x __init__ doesn't try to import
# the v2 modules, and our v2 __init__ has imports that don't exist
# in v0.5.x (e.g. .metadata.heartbeat). The benchmark imports v2
# modules directly by submodule name (e.g.
# `from modelexpress.vllm_weight_transfer import ...`) so the
# image's __init__ is fine.
for f in vllm_weight_transfer.py nemo_rl_v2.py refit_receiver.py training_publisher.py shape_descriptors.py; do
    if [[ -f "$PYTHON_ROOT/modelexpress/$f" ]]; then
        cp "$PYTHON_ROOT/modelexpress/$f" "$TMPDIR/v2_files/$f"
    fi
done

# The benchmark needs its own .py files only (no nested dirs).
cp "$PYTHON_ROOT/benchmarks"/*.py "$TMPDIR/benchmarks/"

echo "  v2 overlay files:"
ls -la "$TMPDIR/v2_files"
echo "  bench overlay files:"
ls -la "$TMPDIR/benchmarks"

V2_SIZE=$(du -sb "$TMPDIR/v2_files" | awk '{print $1}')
BN_SIZE=$(du -sb "$TMPDIR/benchmarks" | awk '{print $1}')
echo "  v2 files overlay:   $((V2_SIZE / 1024)) KiB"
echo "  benchmarks overlay: $((BN_SIZE / 1024)) KiB"

kubectl -n "$NS" create configmap mx-v2-files \
    --from-file="$TMPDIR/v2_files"
kubectl -n "$NS" create configmap mx-v2-benchmarks \
    --from-file="$TMPDIR/benchmarks"

echo "[3/6] Applying $MANIFEST..."
kubectl apply -f "$MANIFEST"

echo "[4/6] Waiting for pod to appear..."
POD=""
for _ in $(seq 1 90); do
    POD=$(kubectl -n "$NS" get pod -l job-name="$JOB" -o name 2>/dev/null | head -1 || true)
    if [[ -n "$POD" ]]; then
        echo "  pod: $POD"
        break
    fi
    sleep 2
done
if [[ -z "$POD" ]]; then
    echo "ERROR: pod did not appear within 180s"
    kubectl -n "$NS" describe job "$JOB" | tail -30
    exit 1
fi

echo "  Waiting for pod to be Ready..."
kubectl -n "$NS" wait --for=condition=ready --timeout=10m "$POD" || {
    echo "ERROR: pod didn't become Ready in 10m. Events:"
    kubectl -n "$NS" describe "$POD" | sed -n '/Events:/,$p'
    exit 1
}

if [[ -n "$WATCH" ]]; then
    echo "Tailing logs (Ctrl-C to detach; the Job keeps running)..."
    kubectl -n "$NS" logs -f "$POD" || true
fi

echo "[5/6] Waiting for the three scenarios to finish writing /results..."
# Poll for tree_fanout.json — the last file the harness writes.
for i in $(seq 1 90); do
    if kubectl -n "$NS" exec "$POD" -- test -f /results/tree_fanout.json 2>/dev/null; then
        echo "  All three result files present."
        break
    fi
    if (( i % 10 == 0 )); then
        echo "  ...still waiting (poll $i/90, ~$((i * 20))s elapsed)"
    fi
    sleep 20
done

TS=$(date +%Y%m%d-%H%M%S)
OUT="$HERE/results-$TS"
mkdir -p "$OUT"
echo "[6/6] Collecting results into $OUT/..."
for scen in elastic_scale compile_target tree_fanout; do
    kubectl -n "$NS" cp "${POD#pod/}:/results/$scen.json" "$OUT/$scen.json" 2>/dev/null || {
        echo "  WARN: $scen.json not collected (run may have failed)"
    }
done

echo
echo "Done. Files:"
ls -la "$OUT"
echo
echo "================ SUMMARY ================"
for scen in elastic_scale compile_target tree_fanout; do
    if [[ -f "$OUT/$scen.json" ]]; then
        echo
        echo "--- $scen ---"
        python3 -c "
import json
d = json.load(open('$OUT/$scen.json'))
print('  wall_seconds:', round(d['wall_seconds'], 2))
print('  derived:')
print('   ', json.dumps(d['derived'], indent=2).replace('\\n', '\\n    '))
print('  receivers:')
for r in d['receivers']:
    cycs = r['cycles']
    n = len(cycs)
    bytes_mb = sum(c['bytes_received'] for c in cycs) / 1e6
    err = sum(1 for c in cycs if c.get('error'))
    avg_bw = (sum(c['bytes_received'] for c in cycs) * 8) / (sum(c['rdma_seconds'] for c in cycs) * 1e9) if sum(c['rdma_seconds'] for c in cycs) > 0 else 0.0
    jl = r.get('join_latency_seconds')
    print(f'    {r[\"receiver_id\"]:<20} join={jl} cycles={n} bytes={bytes_mb:.1f}MB avg={avg_bw:.2f}Gbps errors={err}')
"
    fi
done
echo
echo "Pod ($POD) is sleeping for 10 minutes after the run; results"
echo "are also at /results/ inside it if you need to re-collect."
echo "Delete the Job + ConfigMaps when done:"
echo "  kubectl -n $NS delete job $JOB cm/mx-v2-files cm/mx-v2-benchmarks"
