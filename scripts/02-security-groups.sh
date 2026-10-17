#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

mk_sg() {  # name description
  aws ec2 create-security-group --group-name $PROJECT-$1 --description "$2" \
    --vpc-id $VPC_ID --query GroupId --output text
}
save ALB_SG    $(mk_sg alb-sg    "ALB - HTTP from internet")
save VISITS_SG $(mk_sg visits-sg "visits-service EC2")
save STATS_SG  $(mk_sg stats-sg  "stats-service EC2")
save RDS_SG    $(mk_sg rds-sg    "RDS PostgreSQL")

allow() {  # target-sg port source-sg
  aws ec2 authorize-security-group-ingress --group-id $1 \
    --protocol tcp --port $2 --source-group $3 >/dev/null
}
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
allow $VISITS_SG 8080 $ALB_SG     # ALB -> visits
allow $VISITS_SG 8080 $STATS_SG   # stats -> visits (private IP call)
allow $STATS_SG  8081 $ALB_SG     # ALB -> stats
allow $RDS_SG    5432 $VISITS_SG  # visits -> RDS, nothing else
