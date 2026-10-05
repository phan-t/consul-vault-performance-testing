#!/bin/bash
# Pull the latest perf assets (uploaded to S3 by terraform apply) onto this node.
set -euo pipefail
. /etc/profile.d/perf.sh
aws s3 sync --only-show-errors --delete "s3://$PERF_BUCKET/assets/perf/" /opt/perf/ --exclude 'results/*'
find /opt/perf -name '*.sh' -exec chmod 0755 {} +
echo "synced s3://$PERF_BUCKET/assets/perf/ -> /opt/perf/"
