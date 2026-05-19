#!/bin/bash
# =============================================================================
# Automates the creation of a Security Group with SSH (22) and HTTP (80) access
# Tags the security group with Project=AutomationLab
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration ---------------------------------
REGION="us-east-1"
SG_NAME="devops-sg"
SG_DESCRIPTION="Security group for AutomationLab - allows SSH and HTTP"
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

# ----------------------------- Get VPC ID ------------------------------------
# Source VPC config if available (created by create_vpc.sh)
if [ -f "vpc_config.env" ]; then
    source vpc_config.env
    log "Loaded VPC config from vpc_config.env. Using VPC: $VPC_ID"
else
    log "vpc_config.env not found. Falling back to default VPC ..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        error_exit "No VPC found. Run create_vpc.sh first or ensure a default VPC exists."
    fi
    log "Using default VPC: $VPC_ID"
fi

# ----------------------------- Security Group Creation -----------------------
log "Checking if security group '$SG_NAME' already exists ..."

EXISTING_SG=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
    log "Security group '$SG_NAME' already exists with ID: $EXISTING_SG"
    SG_ID="$EXISTING_SG"
else
    log "Creating security group '$SG_NAME' ..."

    SG_ID=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)

    log "Security group created with ID: $SG_ID"

    # Tag the security group
    aws ec2 create-tags \
        --region "$REGION" \
        --resources "$SG_ID" \
        --tags Key="$TAG_KEY",Value="$TAG_VALUE" Key=Name,Value="$SG_NAME"

    log "Tags applied to security group."

    # ----------------------------- Inbound Rules -----------------------------
    log "Opening port 22 (SSH) ..."
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0

    log "Opening port 80 (HTTP) ..."
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0

    log "Inbound rules added successfully."
fi

# ----------------------------- Display Rules ---------------------------------
log "Fetching security group rules ..."

echo ""
echo "============================================="
echo "  Security Group Created Successfully"
echo "============================================="
echo "  Group Name  : $SG_NAME"
echo "  Group ID    : $SG_ID"
echo "  VPC ID      : $VPC_ID"
echo "  Region      : $REGION"
echo "  Tag         : $TAG_KEY=$TAG_VALUE"
echo "============================================="
echo ""
echo "  Inbound Rules:"

aws ec2 describe-security-groups \
    --region "$REGION" \
    --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[*].{Port:FromPort,Protocol:IpProtocol,CIDR:IpRanges[0].CidrIp}' \
    --output table

echo ""
