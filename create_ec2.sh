#!/bin/bash
# ===============================================================================
# Automates the creation of an EC2 key pair and EC2 instance (Amazon Linux 2)
# Tags the instance with Project=AutomationLab
# ===============================================================================

set -euo pipefail

# ----------------------------- Configuration ---------------------------------
REGION="eu-north-1"
KEY_NAME="automation-lab-key"
INSTANCE_TYPE="t3.micro"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

# ----------------------------- Fetch Latest AMI ------------------------------
# Dynamically fetch the latest Amazon Linux 2 AMI for the configured region
log "Fetching latest Amazon Linux 2 AMI for region $REGION ..."

AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
              "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    error_exit "Could not find a valid Amazon Linux 2 AMI in region $REGION."
fi

log "Using AMI: $AMI_ID"

# ----------------------------- Key Pair Creation -----------------------------
log "Creating EC2 key pair: $KEY_NAME ..."

# Check if the key pair already exists
EXISTING_KEY=$(aws ec2 describe-key-pairs \
    --region "$REGION" \
    --filters "Name=key-name,Values=$KEY_NAME" \
    --query 'KeyPairs[0].KeyName' \
    --output text 2>/dev/null)

if [ "$EXISTING_KEY" == "$KEY_NAME" ]; then
    log "Key pair '$KEY_NAME' already exists. Skipping creation."
else
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem"

    chmod 400 "${KEY_NAME}.pem"
    log "Key pair created and saved to ${KEY_NAME}.pem"
fi

# ----------------------------- EC2 Instance Creation -------------------------
log "Launching EC2 instance ..."

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --count 1 \
    --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=Name,Value=AutomationLab-EC2}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

if [ -z "$INSTANCE_ID" ]; then
    error_exit "Failed to launch EC2 instance."
fi

log "Instance launched. ID: $INSTANCE_ID"
log "Waiting for instance to enter 'running' state ..."

aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

log "Instance is now running."

# ----------------------------- Retrieve Public IP ----------------------------
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

# ----------------------------- Summary ---------------------------------------
echo ""
echo "============================================="
echo "  EC2 Instance Created Successfully"
echo "============================================="
echo "  Instance ID : $INSTANCE_ID"
echo "  Public IP   : $PUBLIC_IP"
echo "  AMI ID      : $AMI_ID"
echo "  Key File    : ${KEY_NAME}.pem"
echo "  Region      : $REGION"
echo "  Tag         : $TAG_KEY=$TAG_VALUE"
echo "============================================="
echo ""
log "To SSH into your instance:"
echo "  ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP"
