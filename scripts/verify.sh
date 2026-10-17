#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"
A=$ACCOUNT_ID R=$AWS_REGION

sim() {  # action resource
  aws iam simulate-principal-policy --policy-source-arn $GH_ROLE_ARN \
    --action-names $1 --resource-arns "$2" \
    --query 'EvaluationResults[0].[EvalActionName,EvalDecision]' --output text
}
echo "--- expected: allowed"
sim ecr:PutImage            arn:aws:ecr:$R:$A:repository/$PROJECT-stats-service
sim ssm:SendCommand         arn:aws:ec2:$R:$A:instance/$VISITS_ID
sim s3:PutObject            arn:aws:s3:::$BUCKET/index.html
sim cloudfront:CreateInvalidation arn:aws:cloudfront::$A:distribution/$DIST_ID
echo "--- expected: implicitDeny"
sim ecr:PutImage            arn:aws:ecr:$R:$A:repository/some-other-repo
sim ssm:SendCommand         arn:aws:ec2:$R:$A:instance/i-0123456789abcdef0
sim s3:PutObject            arn:aws:s3:::some-other-bucket/x
sim ec2:TerminateInstances  "*"

started() {  # instance container
  CID=$(aws ssm send-command --instance-ids $1 --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"docker inspect $2 | grep StartedAt\"]}" \
    --query Command.CommandId --output text)
  aws ssm wait command-executed --command-id $CID --instance-id $1
  aws ssm get-command-invocation --command-id $CID --instance-id $1 \
    --query StandardOutputContent --output text
}
echo "visits: $(started $VISITS_ID visits-service)"
echo "stats:  $(started $STATS_ID stats-service)"
