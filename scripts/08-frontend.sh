#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"
ROOT=$(cd "$(dirname "$0")/.." && pwd)

save BUCKET $PROJECT-frontend-$ACCOUNT_ID
aws s3api create-bucket --bucket $BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION >/dev/null   # required outside us-east-1
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

save OAC_ID $(aws cloudfront create-origin-access-control --origin-access-control-config \
  "Name=$PROJECT-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
  --query OriginAccessControl.Id --output text)

cat > /tmp/cf.json <<EOF
{
  "CallerReference": "$PROJECT-$(date +%s)",
  "Comment": "$PROJECT frontend",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {"Quantity": 1, "Items": [{
    "Id": "s3-frontend",
    "DomainName": "$BUCKET.s3.$AWS_REGION.amazonaws.com",
    "OriginAccessControlId": "$OAC_ID",
    "S3OriginConfig": {"OriginAccessIdentity": ""}
  }]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-frontend",
    "ViewerProtocolPolicy": "allow-all",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }
}
EOF
read DIST_ID DIST_DOMAIN < <(aws cloudfront create-distribution \
  --distribution-config file:///tmp/cf.json \
  --query 'Distribution.[Id,DomainName]' --output text)
save DIST_ID $DIST_ID
save CF_DOMAIN $DIST_DOMAIN

cat > /tmp/bucket-policy.json <<EOF
{"Version":"2012-10-17","Statement":[{
  "Sid":"AllowCloudFrontOAC","Effect":"Allow",
  "Principal":{"Service":"cloudfront.amazonaws.com"},
  "Action":"s3:GetObject",
  "Resource":"arn:aws:s3:::$BUCKET/*",
  "Condition":{"StringEquals":{
    "AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID"}}}]}
EOF
aws s3api put-bucket-policy --bucket $BUCKET --policy file:///tmp/bucket-policy.json

# first upload — work on a copy, never sed the file in the repo
rm -rf /tmp/site && mkdir -p /tmp/site
cp "$ROOT/workloads/frontend/index.html" /tmp/site/
sed -i "s|__API_BASE_URL__|http://$ALB_DNS|" /tmp/site/index.html
grep -q __API_BASE_URL__ /tmp/site/index.html && { echo "placeholder not replaced"; exit 1; }
aws s3 sync /tmp/site s3://$BUCKET/ --delete
echo "open: http://$CF_DOMAIN  (deploy takes ~5 min)"
