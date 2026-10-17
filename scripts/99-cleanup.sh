#!/usr/bin/env bash
set -uo pipefail          # no -e: keep going if one item is already gone
source "$(dirname "$0")/config.env"

echo "1. disable CloudFront (slow, start first)"
aws cloudfront get-distribution-config --id $DIST_ID > /tmp/dc.json
jq '.DistributionConfig.Enabled=false | .DistributionConfig' /tmp/dc.json > /tmp/dc-off.json
aws cloudfront update-distribution --id $DIST_ID --if-match $(jq -r .ETag /tmp/dc.json) \
  --distribution-config file:///tmp/dc-off.json >/dev/null

echo "2. S3"
aws s3 rm s3://$BUCKET --recursive
aws s3api delete-bucket --bucket $BUCKET

echo "3. EC2"
aws ec2 terminate-instances --instance-ids $VISITS_ID $STATS_ID >/dev/null

echo "4. ALB + target groups"
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $VISITS_TG
aws elbv2 delete-target-group --target-group-arn $STATS_TG

echo "5. RDS"
aws rds delete-db-instance --db-instance-identifier $PROJECT-db \
  --skip-final-snapshot --delete-automated-backups >/dev/null
aws ec2 wait instance-terminated --instance-ids $VISITS_ID $STATS_ID
aws rds wait db-instance-deleted --db-instance-identifier $PROJECT-db
aws rds delete-db-subnet-group --db-subnet-group-name $PROJECT-db-subnets

echo "6. security groups (referencing order)"
sleep 30   # ALB/RDS ENIs can linger briefly
for sg in $RDS_SG $VISITS_SG $STATS_SG $ALB_SG; do aws ec2 delete-security-group --group-id $sg; done

echo "7. NAT + EIP"
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID >/dev/null
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID
aws ec2 release-address --allocation-id $EIP_ALLOC

echo "8. subnets, route tables, IGW, VPC"
for s in $PUB_A $PUB_B $PRIV_A $PRIV_B; do aws ec2 delete-subnet --subnet-id $s; done
aws ec2 delete-route-table --route-table-id $PUB_RT
aws ec2 delete-route-table --route-table-id $PRIV_RT
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-vpc --vpc-id $VPC_ID

echo "9. IAM, ECR, parameter"
for svc in visits stats; do
  ROLE=$PROJECT-$svc-ec2-role
  aws iam remove-role-from-instance-profile --instance-profile-name $ROLE --role-name $ROLE
  aws iam delete-instance-profile --instance-profile-name $ROLE
  aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam detach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
done
aws iam delete-role-policy --role-name $PROJECT-visits-ec2-role --policy-name read-db-password
for r in $PROJECT-visits-ec2-role $PROJECT-stats-ec2-role; do aws iam delete-role --role-name $r; done
aws iam delete-role-policy --role-name $PROJECT-github-actions --policy-name deploy
aws iam delete-role --role-name $PROJECT-github-actions
for repo in visits-service stats-service; do aws ecr delete-repository --repository-name $PROJECT-$repo --force >/dev/null; done
aws ssm delete-parameter --name $DB_PARAM

echo "10. delete CloudFront + OAC (after Deployed with Enabled=false)"
aws cloudfront wait distribution-deployed --id $DIST_ID
aws cloudfront delete-distribution --id $DIST_ID \
  --if-match $(aws cloudfront get-distribution --id $DIST_ID --query ETag --output text)
aws cloudfront delete-origin-access-control --id $OAC_ID \
  --if-match $(aws cloudfront get-origin-access-control --id $OAC_ID --query ETag --output text)

echo "11. sweep — everything below should be empty"
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --query 'Addresses[].AllocationId'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws cloudfront list-distributions --query 'DistributionList.Items[].Id'
aws ecr describe-repositories --query 'repositories[].repositoryName'
rm -f "$(dirname "$0")/state.env"
