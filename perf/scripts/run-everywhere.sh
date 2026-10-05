#!/bin/bash
# Run the same test on every load generator at once via SSM Run Command, from
# your workstation (needs AWS credentials and the instance IDs):
#   RUN_ID=leaf-200 ./run-everywhere.sh "RATE=200 HOLD=10m run-k6.sh /opt/perf/k6/consul-leaf.js" i-aaa i-bbb
# Results land in s3://<bucket>/results/<RUN_ID>-loadgen-N-*/
set -euo pipefail
CMD=${1:?usage: run-everywhere.sh "<command>" <instance-id>...}
shift
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
REGION=${AWS_REGION:-ap-southeast-2}

LOGIN_USER=${LOGIN_USER:-ubuntu}
PARAMS=$(jq -n --arg c "sudo -u $LOGIN_USER bash -lc 'export RUN_ID=$RUN_ID; $CMD'" \
  '{commands: [$c], executionTimeout: ["14400"]}')

aws ssm send-command --region "$REGION" \
  --document-name AWS-RunShellScript \
  --instance-ids "$@" \
  --parameters "$PARAMS" \
  --timeout-seconds 600 \
  --comment "perf $RUN_ID" \
  --query Command.CommandId --output text
echo "RUN_ID=$RUN_ID"
