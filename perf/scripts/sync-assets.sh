#!/bin/bash
# Pull the latest perf assets (uploaded to S3 by terraform apply) onto this node.
# Keeps results/ and .repl/ (the replication campaign's tokens and state).
set -euo pipefail
. /etc/profile.d/perf.sh
aws s3 sync --only-show-errors --delete --region "${PERF_BUCKET_REGION:-$AWS_DEFAULT_REGION}" "s3://$PERF_BUCKET/assets/perf/" /opt/perf/ --exclude 'results/*' --exclude '.repl/*'
find /opt/perf -name '*.sh' -exec chmod 0755 {} +
echo "synced s3://$PERF_BUCKET/assets/perf/ -> /opt/perf/"
