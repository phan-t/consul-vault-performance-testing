#!/bin/bash
# Combine every result directory for one RUN_ID (all load generators, all
# tools) into a single report, uploaded to s3://<bucket>/results/<RUN_ID>-summary/.
#   summarise.sh <RUN_ID>
set -euo pipefail
. /etc/profile.d/perf.sh
RUN_ID=${1:?usage: summarise.sh <RUN_ID>}
WORK=$(mktemp -d /opt/perf/results/.summarise.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

aws s3 sync --only-show-errors "s3://$PERF_BUCKET/results/" "$WORK/" \
  --exclude '*' --include "$RUN_ID-*" --exclude '*.png' --exclude '*/metrics.csv'
OUT="/opt/perf/results/$RUN_ID-summary"
python3 /opt/perf/scripts/summarise.py "$WORK" "$RUN_ID" "$OUT"
aws s3 cp --recursive --only-show-errors "$OUT" "s3://$PERF_BUCKET/results/$RUN_ID-summary/"
echo "summary: $OUT/summary.md  ->  s3://$PERF_BUCKET/results/$RUN_ID-summary/"
