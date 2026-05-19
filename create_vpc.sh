#!/bin/bash
# =============================================================================
# Creates a fully configured VPC with:
#   - A VPC (CIDR: 10.0.0.0/16)
#   - A public subnet (CIDR: 10.0.1.0/24)
#   - An Internet Gateway (attached to the VPC)
#   - A Route Table with a default internet route (0.0.0.0/0)
#   - DNS hostnames and DNS resolution enabled
# All resources are tagged with Project=AutomationLab
#
# The VPC ID and Subnet ID are saved to vpc_config.env so other scripts
# can source this file and use them automatically.
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration ---------------------------------
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
AVAILABILITY_ZONE="${REGION}a"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
CONFIG_FILE="vpc_config.env"

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

tag_resource() {
    local RESOURCE_ID=$1
    local NAME=$2
    aws ec2 create-tags \
        --region "$REGION" \
        --resources "$RESOURCE_ID" \
        --tags Key="$TAG_KEY",Value="$TAG_VALUE" Key=Name,Value="$NAME"
}

# ----------------------------- Check Existing VPC ----------------------------
log "Checking for existing AutomationLab VPC ..."

EXISTING_VPC=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null)

if [ "$EXISTING_VPC" != "None" ] && [ -n "$EXISTING_VPC" ]; then
    log "VPC already exists: $EXISTING_VPC. Skipping creation."
    VPC_ID="$EXISTING_VPC"
else

    # ----------------------------- Create VPC --------------------------------
    log "Creating VPC with CIDR $VPC_CIDR ..."

    VPC_ID=$(aws ec2 create-vpc \
        --region "$REGION" \
        --cidr-block "$VPC_CIDR" \
        --query 'Vpc.VpcId' \
        --output text)

    [ -z "$VPC_ID" ] && error_exit "Failed to create VPC."
    log "VPC created: $VPC_ID"

    tag_resource "$VPC_ID" "AutomationLab-VPC"

    # ----------------------------- Enable DNS --------------------------------
    log "Enabling DNS hostnames and DNS resolution ..."

    aws ec2 modify-vpc-attribute \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --enable-dns-hostnames

    aws ec2 modify-vpc-attribute \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --enable-dns-support

    log "DNS settings enabled."
fi

# ----------------------------- Create Subnet ---------------------------------
log "Checking for existing subnet in $AVAILABILITY_ZONE ..."

EXISTING_SUBNET=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'Subnets[0].SubnetId' \
    --output text 2>/dev/null)

if [ "$EXISTING_SUBNET" != "None" ] && [ -n "$EXISTING_SUBNET" ]; then
    log "Subnet already exists: $EXISTING_SUBNET. Skipping."
    SUBNET_ID="$EXISTING_SUBNET"
else
    log "Creating public subnet with CIDR $SUBNET_CIDR in $AVAILABILITY_ZONE ..."

    SUBNET_ID=$(aws ec2 create-subnet \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --cidr-block "$SUBNET_CIDR" \
        --availability-zone "$AVAILABILITY_ZONE" \
        --query 'Subnet.SubnetId' \
        --output text)

    [ -z "$SUBNET_ID" ] && error_exit "Failed to create subnet."
    log "Subnet created: $SUBNET_ID"

    tag_resource "$SUBNET_ID" "AutomationLab-Subnet"

    # Enable auto-assign public IP on launch
    aws ec2 modify-subnet-attribute \
        --region "$REGION" \
        --subnet-id "$SUBNET_ID" \
        --map-public-ip-on-launch

    log "Auto-assign public IP enabled on subnet."
fi

# ----------------------------- Create Internet Gateway -----------------------
log "Checking for existing Internet Gateway ..."

EXISTING_IGW=$(aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text 2>/dev/null)

if [ "$EXISTING_IGW" != "None" ] && [ -n "$EXISTING_IGW" ]; then
    log "Internet Gateway already attached: $EXISTING_IGW. Skipping."
    IGW_ID="$EXISTING_IGW"
else
    log "Creating Internet Gateway ..."

    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$REGION" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)

    [ -z "$IGW_ID" ] && error_exit "Failed to create Internet Gateway."
    log "Internet Gateway created: $IGW_ID"

    tag_resource "$IGW_ID" "AutomationLab-IGW"

    log "Attaching Internet Gateway to VPC ..."
    aws ec2 attach-internet-gateway \
        --region "$REGION" \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID"

    log "Internet Gateway attached."
fi

# ----------------------------- Create Route Table ----------------------------
log "Checking for existing Route Table ..."

EXISTING_RT=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
              "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'RouteTables[0].RouteTableId' \
    --output text 2>/dev/null)

if [ "$EXISTING_RT" != "None" ] && [ -n "$EXISTING_RT" ]; then
    log "Route Table already exists: $EXISTING_RT. Skipping."
    RT_ID="$EXISTING_RT"
else
    log "Creating Route Table ..."

    RT_ID=$(aws ec2 create-route-table \
        --region "$REGION" \
        --vpc-id "$VPC_ID" \
        --query 'RouteTable.RouteTableId' \
        --output text)

    [ -z "$RT_ID" ] && error_exit "Failed to create Route Table."
    log "Route Table created: $RT_ID"

    tag_resource "$RT_ID" "AutomationLab-RT"

    # Add default route to the internet via the IGW
    log "Adding default internet route (0.0.0.0/0) ..."
    aws ec2 create-route \
        --region "$REGION" \
        --route-table-id "$RT_ID" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$IGW_ID"

    # Associate route table with the subnet
    log "Associating Route Table with Subnet ..."
    aws ec2 associate-route-table \
        --region "$REGION" \
        --route-table-id "$RT_ID" \
        --subnet-id "$SUBNET_ID"

    log "Route Table configured and associated."
fi

# ----------------------------- Save Config to File ---------------------------
log "Saving VPC config to $CONFIG_FILE ..."

cat > "$CONFIG_FILE" <<EOF
# Auto-generated by create_vpc.sh — $(date)
export VPC_ID="$VPC_ID"
export SUBNET_ID="$SUBNET_ID"
export IGW_ID="$IGW_ID"
export REGION="$REGION"
EOF

log "Config saved. Source it in other scripts with: source $CONFIG_FILE"

# ----------------------------- Summary ---------------------------------------
echo ""
echo "============================================="
echo "  VPC Setup Complete"
echo "============================================="
echo "  VPC ID       : $VPC_ID"
echo "  Subnet ID    : $SUBNET_ID"
echo "  IGW ID       : $IGW_ID"
echo "  Route Table  : $RT_ID"
echo "  CIDR Block   : $VPC_CIDR"
echo "  Subnet CIDR  : $SUBNET_CIDR"
echo "  Region       : $REGION"
echo "  Tag          : $TAG_KEY=$TAG_VALUE"
echo "  Config File  : $CONFIG_FILE"
echo "============================================="
echo ""
