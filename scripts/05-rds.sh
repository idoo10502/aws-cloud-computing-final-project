#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

aws rds create-db-subnet-group --db-subnet-group-name $PROJECT-db-subnets \
  --db-subnet-group-description "private subnets only" \
  --subnet-ids $PRIV_A $PRIV_B >/dev/null

DB_PASSWORD=$(openssl rand -hex 20)
aws ssm put-parameter --name $DB_PARAM --type SecureString \
  --value "$DB_PASSWORD" --overwrite >/dev/null

aws rds create-db-instance --db-instance-identifier $PROJECT-db \
  --engine postgres --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username appuser --master-user-password "$DB_PASSWORD" \
  --db-name visits \
  --db-subnet-group-name $PROJECT-db-subnets --vpc-security-group-ids $RDS_SG \
  --no-publicly-accessible --no-multi-az --backup-retention-period 0 >/dev/null
unset DB_PASSWORD

echo "waiting for RDS (5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier $PROJECT-db
save DB_HOST $(aws rds describe-db-instances --db-instance-identifier $PROJECT-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
save DB_NAME visits
save DB_USER appuser
