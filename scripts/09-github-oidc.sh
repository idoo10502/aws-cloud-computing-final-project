#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"
REPO=${GITHUB_REPO:?set GITHUB_REPO=owner/repo}
ROLE=$PROJECT-github-actions
OIDC=token.actions.githubusercontent.com

aws iam create-open-id-connect-provider --url https://$OIDC \
  --client-id-list sts.amazonaws.com >/dev/null 2>&1 || echo "OIDC provider exists"

cat > /tmp/gh-trust.json <<EOF
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Federated":"arn:aws:iam::$ACCOUNT_ID:oidc-provider/$OIDC"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{
    "$OIDC:aud":"sts.amazonaws.com",
    "$OIDC:sub":"repo:$REPO:ref:refs/heads/main"}}}]}
EOF

A=$ACCOUNT_ID R=$AWS_REGION
cat > /tmp/gh-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"EcrAuth","Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Sid":"EcrPush","Effect":"Allow",
  "Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],
  "Resource":["arn:aws:ecr:$R:$A:repository/$PROJECT-visits-service",
              "arn:aws:ecr:$R:$A:repository/$PROJECT-stats-service"]},
 {"Sid":"SsmSend","Effect":"Allow","Action":"ssm:SendCommand",
  "Resource":["arn:aws:ec2:$R:$A:instance/$VISITS_ID","arn:aws:ec2:$R:$A:instance/$STATS_ID",
              "arn:aws:ssm:$R::document/AWS-RunShellScript"]},
 {"Sid":"SsmRead","Effect":"Allow","Action":["ssm:GetCommandInvocation","ssm:ListCommandInvocations"],"Resource":"*"},
 {"Sid":"S3List","Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$BUCKET"},
 {"Sid":"S3Write","Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:DeleteObject"],
  "Resource":"arn:aws:s3:::$BUCKET/*"},
 {"Sid":"CfInvalidate","Effect":"Allow","Action":"cloudfront:CreateInvalidation",
  "Resource":"arn:aws:cloudfront::$A:distribution/$DIST_ID"}
]}
EOF

aws iam create-role --role-name $ROLE --assume-role-policy-document file:///tmp/gh-trust.json >/dev/null
aws iam put-role-policy --role-name $ROLE --policy-name deploy --policy-document file:///tmp/gh-policy.json
save GH_ROLE_ARN arn:aws:iam::$ACCOUNT_ID:role/$ROLE

# GitHub repository variables (not secrets — none of these are sensitive)
for kv in AWS_REGION=$AWS_REGION AWS_ROLE_ARN=$GH_ROLE_ARN \
  VISITS_INSTANCE_ID=$VISITS_ID STATS_INSTANCE_ID=$STATS_ID VISITS_PRIVATE_IP=$VISITS_PRIVATE_IP \
  DB_HOST=$DB_HOST DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PARAM=$DB_PARAM \
  ALB_DNS=$ALB_DNS S3_BUCKET=$BUCKET CF_DIST_ID=$DIST_ID CF_DOMAIN=$CF_DOMAIN; do
  gh variable set "${kv%%=*}" --repo "$REPO" --body "${kv#*=}"
done
