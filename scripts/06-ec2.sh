#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

launch() {  # name subnet sg instance-profile
  aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
    --subnet-id $2 --security-group-ids $3 \
    --iam-instance-profile Name=$4 \
    --user-data file://$(dirname "$0")/user-data.sh \
    --metadata-options HttpTokens=required \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT-$1}]" \
    --query 'Instances[0].InstanceId' --output text
}
save VISITS_ID $(launch visits-service $PRIV_A $VISITS_SG $PROJECT-visits-ec2-role)
save STATS_ID  $(launch stats-service  $PRIV_B $STATS_SG  $PROJECT-stats-ec2-role)

aws ec2 wait instance-running --instance-ids $VISITS_ID $STATS_ID
save VISITS_PRIVATE_IP $(aws ec2 describe-instances --instance-ids $VISITS_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

echo "waiting for SSM agent..."
until [ "$(aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=$VISITS_ID,$STATS_ID \
  --query 'length(InstanceInformationList[?PingStatus==`Online`])')" = 2 ]; do sleep 15; done
echo "both instances online in SSM"
