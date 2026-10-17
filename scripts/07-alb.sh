#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

mk_tg() {  # name port
  aws elbv2 create-target-group --name $PROJECT-$1-tg \
    --protocol HTTP --port $2 --vpc-id $VPC_ID --target-type instance \
    --health-check-path /health \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}
save VISITS_TG $(mk_tg visits 8080)
save STATS_TG  $(mk_tg stats  8081)
aws elbv2 register-targets --target-group-arn $VISITS_TG --targets Id=$VISITS_ID
aws elbv2 register-targets --target-group-arn $STATS_TG  --targets Id=$STATS_ID

save ALB_ARN $(aws elbv2 create-load-balancer --name $PROJECT-alb \
  --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
save ALB_DNS $(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

save LISTENER_ARN $(aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions 'Type=fixed-response,FixedResponseConfig={StatusCode=404,ContentType=text/plain,MessageBody=no-route}' \
  --query 'Listeners[0].ListenerArn' --output text)

aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 10 \
  --conditions Field=path-pattern,Values='/visits*' \
  --actions Type=forward,TargetGroupArn=$VISITS_TG >/dev/null
aws elbv2 create-rule --listener-arn $LISTENER_ARN --priority 20 \
  --conditions Field=path-pattern,Values='/stats*' \
  --actions Type=forward,TargetGroupArn=$STATS_TG >/dev/null
echo "ALB: http://$ALB_DNS"
