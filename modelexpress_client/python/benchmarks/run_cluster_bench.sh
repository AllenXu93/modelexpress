#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Drive the MX v2 benchmark Job on the kavin cluster + collect results
# into ./results-<timestamp>/.
#
# Prerequisites:
#   - kubectl pointed at the right cluster + context
#   - `kavin` namespace has modelexpress-server running
#   - prime-rl image (or any image with modelexpress installed) is
#     reachable from the namespace's nodeSelector
#
# Usage:
#   ./run_cluster_bench.sh           # runs all 3 scenarios, collects JSON
#   ./run_cluster_bench.sh --watch   # also tail logs while it runs

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/k8s/bench-elastic.yaml"
NS="kavin"
JOB="mx-bench-elastic"

WATCH=""
if [[ "${1:-}" == "--watch" ]]; then
    WATCH=1
fi

echo "[1/4] Cleaning up any prior Job..."
kubectl -n "$NS" delete job "$JOB" --ignore-not-found=true

echo "[2/4] Applying $MANIFEST..."
kubectl apply -f "$MANIFEST"

echo "[3/4] Waiting for pod to start..."
for i in $(seq 1 60); do
    POD=$(kubectl -n "$NS" get pod -l job-name="$JOB" -o name 2>/dev/null | head -1 || true)
    if [[ -n "$POD" ]]; then
        echo "  pod: $POD"
        break
    fi
    sleep 2
done
if [[ -z "$POD" ]]; then
    echo "ERROR: pod did not appear within 120s"
    exit 1
fi

if [[ -n "$WATCH" ]]; then
    echo "Tailing logs (Ctrl-C to detach; the Job continues)..."
    kubectl -n "$NS" logs -f "$POD" || true
fi

echo "[4/4] Waiting for Job to complete..."
kubectl -n "$NS" wait --for=condition=complete --timeout=30m "job/$JOB" || {
    echo "Job didn't complete in 30m. Final state:"
    kubectl -n "$NS" describe job "$JOB" | tail -30
    echo
    echo "Last log lines:"
    kubectl -n "$NS" logs "$POD" --tail=80 || true
    exit 1
}

TS=$(date +%Y%m%d-%H%M%S)
OUT="$HERE/results-$TS"
mkdir -p "$OUT"
echo "Collecting results into $OUT/..."
kubectl -n "$NS" cp "${POD#pod/}:/results" "$OUT/" || {
    echo "WARN: kubectl cp failed; pulling files individually..."
    for scen in elastic_scale compile_target tree_fanout; do
        kubectl -n "$NS" exec "$POD" -- cat "/results/$scen.json" > "$OUT/$scen.json" || true
    done
}
echo
echo "Done. Files:"
ls -la "$OUT"
echo
echo "Summary:"
for scen in elastic_scale compile_target tree_fanout; do
    if [[ -f "$OUT/$scen.json" ]]; then
        echo "  $scen:"
        python3 -c "
import json
d = json.load(open('$OUT/$scen.json'))
print('    wall_seconds:', round(d['wall_seconds'], 2))
print('    derived:', json.dumps(d['derived']['scenario_specific'], indent=6).replace('\\n', '\\n    '))
"
    fi
done
echo
echo "To populate pensieve/RL/PrimeRL/11_benchmark_results.md, paste the"
echo "per-receiver tables from these JSON files into the matching sections."
