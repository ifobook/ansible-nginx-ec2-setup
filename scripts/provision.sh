#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

export AWS_PROFILE=devops-admin
export AWS_REGION=eu-west-1
export AWS_DEFAULT_REGION=eu-west-1
export AWS_PAGER=""

PROJECT="ansible-nginx-ec2-setup"
INSTANCE_NAME="ansible-nginx-ec2"
SG_NAME="ansible-nginx-sg"
KEY_NAME="ansible-nginx-ec2"
STATE_FILE=".aws-resources.env"

VPC_ID="vpc-04d502973aa246d68"
SUBNET_ID="subnet-0b4d67c176ade29fd"
AMI_ID="ami-0ae26e505e119d6d4"
INSTANCE_TYPE="t3.micro"

if [[ -e "$STATE_FILE" ]]; then
    echo "Resource state file already exists."
    echo "Inspect existing resources before provisioning again."
    exit 1
fi

PUBLIC_IP=$(curl -4 -fsS --max-time 15 https://checkip.amazonaws.com)

if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unable to determine public IPv4 address."
    exit 1
fi

test -f "$HOME/.ssh/ansible-nginx-ec2.pub"

umask 077

printf 'AWS_REGION=%s\nPROJECT=%s\n' \
    "$AWS_REGION" "$PROJECT" > "$STATE_FILE"

echo "===== CREATING SECURITY GROUP ====="

SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "SSH and HTTP access for Ansible Nginx project" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$SG_NAME}]" \
    --query GroupId \
    --output text)

printf 'SG_ID=%s\n' "$SG_ID" >> "$STATE_FILE"

echo "Security group: $SG_ID"

echo "===== CONFIGURING INBOUND RULES ====="

aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$PUBLIC_IP/32"

aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

echo "===== IMPORTING SSH PUBLIC KEY ====="

KEY_ID=$(aws ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material "fileb://$HOME/.ssh/ansible-nginx-ec2.pub" \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$PROJECT}]" \
    --query KeyPairId \
    --output text)

printf 'KEY_ID=%s\nKEY_NAME=%s\n' \
    "$KEY_ID" "$KEY_NAME" >> "$STATE_FILE"

echo "===== LAUNCHING EC2 INSTANCE ====="

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --count 1 \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --associate-public-ip-address \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --credit-specification "CpuCredits=standard" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT}]" \
      "ResourceType=volume,Tags=[{Key=Project,Value=$PROJECT}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

printf 'INSTANCE_ID=%s\n' "$INSTANCE_ID" >> "$STATE_FILE"

echo "Instance ID: $INSTANCE_ID"

echo "===== WAITING FOR INSTANCE ====="

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID"

EC2_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

printf 'EC2_IP=%s\n' "$EC2_IP" >> "$STATE_FILE"

echo "===== UPDATING ANSIBLE INVENTORY ====="

cat > inventory.ini <<INVENTORY
[webservers]
nginx-server ansible_host=$EC2_IP

[webservers:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/ansible-nginx-ec2
ansible_python_interpreter=/usr/bin/python3
INVENTORY

echo "===== WAITING FOR EC2 STATUS CHECKS ====="

aws ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID"

echo "===== PROVISIONING COMPLETE ====="

echo "Instance ID: $INSTANCE_ID"
echo "Security group: $SG_ID"
echo "Public IP: $EC2_IP"
echo "Website: http://$EC2_IP"
echo "Resource records: $STATE_FILE"
