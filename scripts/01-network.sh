# ===== scripts/01-network.sh =====
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.env"

VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
save VPC_ID $VPC_ID

mk_subnet() {  # name cidr az
  aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-$1}]" \
    --query Subnet.SubnetId --output text
}
save PUB_A  $(mk_subnet pub-a  $PUB_A_CIDR  $AZ_A)
save PUB_B  $(mk_subnet pub-b  $PUB_B_CIDR  $AZ_B)
save PRIV_A $(mk_subnet priv-a $PRIV_A_CIDR $AZ_A)
save PRIV_B $(mk_subnet priv-b $PRIV_B_CIDR $AZ_B)

IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
save IGW_ID $IGW_ID

PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID >/dev/null
for s in $PUB_A $PUB_B; do aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $s >/dev/null; done
save PUB_RT $PUB_RT

save EIP_ALLOC $(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
save NAT_ID $(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP_ALLOC \
  --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID

PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PRIV_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID >/dev/null
for s in $PRIV_A $PRIV_B; do aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $s >/dev/null; done
save PRIV_RT $PRIV_RT
echo "network ready: $VPC_ID"