#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

save REGISTRY $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
aws ecr get-login-password | docker login --username AWS --password-stdin $REGISTRY

for svc in visits-service stats-service; do
  aws ecr create-repository --repository-name $PROJECT-$svc \
    --image-scanning-configuration scanOnPush=true >/dev/null
  IMAGE=$REGISTRY/$PROJECT-$svc:bootstrap
  docker build --platform linux/amd64 -t $IMAGE "$ROOT/workloads/$svc"
  docker push $IMAGE
done
