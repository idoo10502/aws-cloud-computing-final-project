#!/usr/bin/env bash
# scripts/ssm-deploy.sh <visits|stats> <image-uri> <instance-id>
# Runs locally or in CI. Sends a deploy script to the instance via SSM Run Command.
# The DB password is NEVER in the command — the instance fetches it itself.
set -euo pipefail
SVC=$1 IMAGE=$2 INSTANCE_ID=$3
REGISTRY=${IMAGE%%/*}
: "${AWS_REGION:?}" "${ALLOWED_ORIGIN:?}"

if [ "$SVC" = visits ]; then
  : "${DB_HOST:?}" "${DB_NAME:?}" "${DB_USER:?}" "${DB_PARAM:?}"
  PORT=8080
  # single quotes: $(...) is sent as text and runs ON THE INSTANCE
  PRE='DB_PASSWORD=$(aws ssm get-parameter --name '"$DB_PARAM"' --with-decryption --query Parameter.Value --output text)'
  ENVS="-e DB_HOST=$DB_HOST -e DB_NAME=$DB_NAME -e DB_USER=$DB_USER"
  ENVS="$ENVS -e DB_PASSWORD=\"\$DB_PASSWORD\" -e PGSSLMODE=require"
else
  : "${VISITS_PRIVATE_IP:?}"
  PORT=8081
  PRE=':'
  ENVS="-e VISITS_SERVICE_URL=http://$VISITS_PRIVATE_IP:8080"
fi

REMOTE=$(cat <<EOF
set -eu
export AWS_DEFAULT_REGION=$AWS_REGION
aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY
docker pull $IMAGE
$PRE
docker rm -f $SVC-service 2>/dev/null || true
docker run -d --name $SVC-service --restart unless-stopped -p $PORT:$PORT \\
  $ENVS -e ALLOWED_ORIGIN=$ALLOWED_ORIGIN $IMAGE
EOF
)

CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "deploy $SVC" \
  --parameters "$(jq -n --arg s "$REMOTE" '{commands:[$s]}')" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID -> $INSTANCE_ID"

aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" || true
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '{status:Status,stdout:StandardOutputContent,stderr:StandardErrorContent}'
[ "$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query Status --output text)" = Success ]

# ── first manual deploy (run from repo root) ──
#   source scripts/config.env
#   export ALLOWED_ORIGIN=http://$CF_DOMAIN
#   scripts/ssm-deploy.sh visits $REGISTRY/final-project-visits-service:bootstrap $VISITS_ID
#   scripts/ssm-deploy.sh stats  $REGISTRY/final-project-stats-service:bootstrap  $STATS_ID
