#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

cat > /tmp/ec2-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Service":"ec2.amazonaws.com"},
  "Action":"sts:AssumeRole"}]}
EOF

for svc in visits stats; do
  ROLE=$PROJECT-$svc-ec2-role
  aws iam create-role --role-name $ROLE \
    --assume-role-policy-document file:///tmp/ec2-trust.json >/dev/null
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  aws iam create-instance-profile --instance-profile-name $ROLE >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name $ROLE --role-name $ROLE
done

save DB_PARAM /$PROJECT/db-password
cat > /tmp/read-db-password.json <<EOF
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Action":"ssm:GetParameter",
  "Resource":"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter$DB_PARAM"}]}
EOF
aws iam put-role-policy --role-name $PROJECT-visits-ec2-role \
  --policy-name read-db-password --policy-document file:///tmp/read-db-password.json
