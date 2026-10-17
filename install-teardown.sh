#!/usr/bin/env bash
# Creates scripts/teardown/ with all undo scripts. Run from the repo root: bash install-teardown.sh
set -e
mkdir -p scripts/teardown
cat > scripts/teardown/_lib.sh <<'__EOF__'
#!/usr/bin/env bash
# shared header for teardown scripts - sourced, not run
T_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S_DIR="$(cd "$T_DIR/.." && pwd)"
set -uo pipefail
source "$S_DIR/config.env"
[ -f "$S_DIR/state.env" ] && source "$S_DIR/state.env"
export AWS_PAGER=""
say() { echo "== $*"; }
# run a command, never abort the teardown if the resource is already gone
try() { "$@" >/dev/null 2>&1 && echo "   ok: $1 $2 $3" || echo "   skip: $1 $2 $3 (missing or already deleted)"; }
# retry CMD up to N times, 15s apart (for DependencyViolation while AWS finishes cleanup)
retry() { local n=$1; shift; for ((i=1;i<=n;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 15; done; return 1; }
__EOF__
cat > scripts/teardown/00-teardown-all.sh <<'__EOF__'
#!/usr/bin/env bash
# Deletes everything the project scripts created, in reverse order. Safe to rerun.
# Usage: bash scripts/teardown/00-teardown-all.sh [--yes]
D="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Delete ALL project resources in AWS? type yes: " a
  [ "$a" = "yes" ] || { echo "aborted"; exit 1; }
fi
for s in 09-undo-github-oidc 08-undo-frontend 07-undo-alb 06-undo-ec2 05-undo-rds 04-undo-iam-ec2 03-undo-ecr 02-undo-security-groups 01-undo-network; do
  echo; echo "########## $s"
  bash "$D/$s.sh"
done
echo; bash "$D/check-leftovers.sh"
__EOF__
cat > scripts/teardown/01-undo-network.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 01-network.sh : NAT, Elastic IP, route tables, subnets, IGW, VPC.
# Works from what actually exists in the VPC, so it also cleans partial runs.
source "$(dirname "$0")/_lib.sh"
VPC=${VPC_ID:-$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)}
if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then echo "   no VPC found - checking only for leftover Elastic IPs"; fi

if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  say "NAT gateways (the expensive one)"
  for nat in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text); do
    try aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
  done
  echo "   waiting for NAT deletion..."
  for i in $(seq 1 40); do
    left=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=pending,available,deleting" --query 'length(NatGateways)' --output text)
    [ "$left" = "0" ] && break; sleep 15
  done
fi

say "Elastic IPs"
for a in ${EIP_ALLOC:-} $(aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null); do
  retry 4 aws ec2 release-address --allocation-id "$a" && echo "   released $a" || true
done

if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  say "route tables"
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text); do
    for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
      try aws ec2 disassociate-route-table --association-id "$assoc"
    done
    try aws ec2 delete-route-table --route-table-id "$rt"
  done
  say "subnets"
  for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text); do
    retry 6 aws ec2 delete-subnet --subnet-id "$s" && echo "   ok: $s" || echo "   FAILED: $s (ENI still attached - rerun in a few minutes)"
  done
  say "internet gateway"
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query 'InternetGateways[].InternetGatewayId' --output text); do
    try aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
    try aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
  say "VPC"
  if retry 6 aws ec2 delete-vpc --vpc-id "$VPC"; then
    echo "   ok: $VPC"; rm -f "$S_DIR/state.env" && echo "   state.env removed"
  else
    echo "   FAILED: VPC still has dependencies (check security groups / ENIs), state.env kept"
  fi
fi
__EOF__
cat > scripts/teardown/02-undo-security-groups.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 02-security-groups.sh : revokes cross-references first, then deletes the 4 groups
source "$(dirname "$0")/_lib.sh"
VPC=${VPC_ID:-$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT-vpc" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)}
SGS=""
for n in rds-sg visits-sg stats-sg alb-sg; do
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJECT-$n" "Name=vpc-id,Values=$VPC" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [ -n "$id" ] && [ "$id" != "None" ] && SGS="$SGS $id"
done
[ -z "$SGS" ] && { echo "   no security groups found"; exit 0; }
say "revoking ingress rules"
for sg in $SGS; do
  perms=$(aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
  [ "$perms" != "[]" ] && [ -n "$perms" ] && aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$perms" >/dev/null 2>&1
done
say "deleting groups"
for sg in $SGS; do
  retry 8 aws ec2 delete-security-group --group-id "$sg" && echo "   ok: $sg" || echo "   FAILED: $sg (an ENI still uses it - wait a few minutes and rerun)"
done
__EOF__
cat > scripts/teardown/03-undo-ecr.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 03-ecr.sh : both repositories, with all images
source "$(dirname "$0")/_lib.sh"
for svc in visits-service stats-service; do
  say "ECR $PROJECT-$svc"
  try aws ecr delete-repository --repository-name "$PROJECT-$svc" --force
done
__EOF__
cat > scripts/teardown/04-undo-iam-ec2.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 04-iam-ec2.sh : EC2 roles + instance profiles
source "$(dirname "$0")/_lib.sh"
for svc in visits stats; do
  ROLE=$PROJECT-$svc-ec2-role
  say "$ROLE"
  try aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  try aws iam delete-instance-profile --instance-profile-name "$ROLE"
  for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
    try aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p"
  done
  for a in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    try aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$a"
  done
  try aws iam delete-role --role-name "$ROLE"
done
__EOF__
cat > scripts/teardown/05-undo-rds.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 05-rds.sh : DB instance (no final snapshot), subnet group, password parameter (takes ~5-10 min)
source "$(dirname "$0")/_lib.sh"
DB=$PROJECT-db
if aws rds describe-db-instances --db-instance-identifier "$DB" >/dev/null 2>&1; then
  say "RDS $DB"
  aws rds modify-db-instance --db-instance-identifier "$DB" --no-deletion-protection --apply-immediately >/dev/null 2>&1
  try aws rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups
  say "waiting for RDS deletion (5-10 min)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB"
fi
say "DB subnet group"
retry 6 aws rds delete-db-subnet-group --db-subnet-group-name "$PROJECT-db-subnets" && echo "   ok" || echo "   skip (missing)"
say "SSM parameter"
try aws ssm delete-parameter --name "${DB_PARAM:-/$PROJECT/db-password}"
__EOF__
cat > scripts/teardown/06-undo-ec2.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 06-ec2.sh : terminates both instances
source "$(dirname "$0")/_lib.sh"
IDS="${VISITS_ID:-} ${STATS_ID:-}"
IDS=$(echo $IDS)
if [ -z "$IDS" ]; then
  IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=visits-service,stats-service" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
fi
if [ -n "$IDS" ]; then
  say "terminating: $IDS"
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS && echo "   terminated"
else
  echo "   no instances found"
fi
__EOF__
cat > scripts/teardown/07-undo-alb.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 07-alb.sh : load balancer (listener + rules go with it) and target groups
source "$(dirname "$0")/_lib.sh"
ALB_ARN=${ALB_ARN:-$(aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)}
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  say "ALB"
  try aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  say "waiting for ALB deletion..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null
fi
for name in visits stats; do
  TG=$(aws elbv2 describe-target-groups --names "$PROJECT-$name-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  if [ -n "$TG" ] && [ "$TG" != "None" ]; then
    say "target group $PROJECT-$name-tg"
    retry 8 aws elbv2 delete-target-group --target-group-arn "$TG" && echo "   ok" || echo "   FAILED - delete it manually in the console"
  fi
done
__EOF__
cat > scripts/teardown/08-undo-frontend.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 08-frontend.sh : CloudFront distribution + OAC + S3 bucket (takes ~5-15 min)
source "$(dirname "$0")/_lib.sh"
BUCKET=${BUCKET:-$PROJECT-frontend-$ACCOUNT_ID}

if [ -z "${DIST_ID:-}" ]; then
  DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$PROJECT frontend'].Id | [0]" --output text 2>/dev/null)
  [ "$DIST_ID" = "None" ] && DIST_ID=""
fi

if [ -n "${DIST_ID:-}" ]; then
  say "CloudFront $DIST_ID: disable"
  CFG=$(aws cloudfront get-distribution-config --id "$DIST_ID" 2>/dev/null)
  if [ -n "$CFG" ]; then
    ETAG=$(echo "$CFG" | jq -r .ETag)
    if [ "$(echo "$CFG" | jq -r .DistributionConfig.Enabled)" = "true" ]; then
      echo "$CFG" | jq '.DistributionConfig | .Enabled=false' > /tmp/cf-disable.json
      aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
        --distribution-config file:///tmp/cf-disable.json >/dev/null
    fi
    say "waiting until the distribution is deployed (disabled)..."
    aws cloudfront wait distribution-deployed --id "$DIST_ID"
    ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)
    try aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG"
  fi
fi

OAC_ID=${OAC_ID:-$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name=='$PROJECT-oac'].Id | [0]" --output text 2>/dev/null)}
if [ -n "$OAC_ID" ] && [ "$OAC_ID" != "None" ]; then
  say "OAC $OAC_ID"
  ETAG=$(aws cloudfront get-origin-access-control --id "$OAC_ID" --query ETag --output text 2>/dev/null)
  try aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$ETAG"
fi

say "S3 bucket $BUCKET"
try aws s3 rm "s3://$BUCKET" --recursive
try aws s3api delete-bucket-policy --bucket "$BUCKET"
try aws s3api delete-bucket --bucket "$BUCKET"
__EOF__
cat > scripts/teardown/09-undo-github-oidc.sh <<'__EOF__'
#!/usr/bin/env bash
# undoes 09-github-oidc.sh  (does NOT delete the shared OIDC provider from lesson 5)
source "$(dirname "$0")/_lib.sh"
ROLE=$PROJECT-github-actions
say "GitHub Actions role $ROLE"
try aws iam delete-role-policy --role-name "$ROLE" --policy-name deploy
for p in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  try aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$p"
done
try aws iam delete-role --role-name "$ROLE"
if [ -n "${GITHUB_REPO:-}" ] && command -v gh >/dev/null; then
  say "GitHub repository variables"
  for v in $(gh variable list --repo "$GITHUB_REPO" --json name --jq '.[].name' 2>/dev/null); do
    try gh variable delete "$v" --repo "$GITHUB_REPO"
  done
fi
__EOF__
cat > scripts/teardown/check-leftovers.sh <<'__EOF__'
#!/usr/bin/env bash
# lists billable resources still alive in the region; every line should be empty / []
source "$(dirname "$0")/_lib.sh"
echo "region: $AWS_REGION"
echo "VPCs (project):  $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-vpc --query 'Vpcs[].VpcId' --output text)"
echo "NAT gateways:    $(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text)"
echo "Elastic IPs:     $(aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text)"
echo "EC2 running:     $(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "RDS:             $(aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text)"
echo "Load balancers:  $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text)"
echo "CloudFront:      $(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text 2>/dev/null)"
echo "S3 (project):    $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'$PROJECT')].Name" --output text)"
echo "ECR (project):   $(aws ecr describe-repositories --query "repositories[?starts_with(repositoryName,'$PROJECT')].repositoryName" --output text 2>/dev/null)"
__EOF__
sed -i 's/\r$//' scripts/teardown/*.sh
chmod +x scripts/teardown/*.sh
ls scripts/teardown
