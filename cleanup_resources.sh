#!/bin/bash
# =============================================================================
# Safely removes all AWS resources tagged with Project=AutomationLab:
#   - EC2 instances
#   - EC2 key pairs
#   - Security groups
#   - S3 buckets
#   - VPC
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration ---------------------------------
REGION="us-east-1"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
KEY_NAME="automation-lab-key"

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

confirm() {
    read -r -p "$1 [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------- Safety Prompt ---------------------------------
echo ""
echo "============================================="
echo "  WARNING: AutomationLab Cleanup Script"
echo "============================================="
echo "  This will delete ALL resources tagged:"
echo "  $TAG_KEY=$TAG_VALUE in region $REGION"
echo "============================================="
echo ""

if ! confirm "Are you sure you want to proceed?"; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""

# ----------------------------- Terminate EC2 Instances -----------------------
log "Looking for EC2 instances tagged $TAG_KEY=$TAG_VALUE ..."

INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
              "Name=instance-state-name,Values=pending,running,stopped,stopping" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ -z "$INSTANCE_IDS" ]; then
    log "No EC2 instances found."
else
    log "Found instances: $INSTANCE_IDS"
    log "Terminating instances ..."

    aws ec2 terminate-instances \
        --region "$REGION" \
        --instance-ids $INSTANCE_IDS

    log "Waiting for instances to terminate ..."
    aws ec2 wait instance-terminated \
        --region "$REGION" \
        --instance-ids $INSTANCE_IDS

    log "All EC2 instances terminated."
fi

# ----------------------------- Delete Key Pair --------------------------------
log "Checking for key pair: $KEY_NAME ..."

EXISTING_KEY=$(aws ec2 describe-key-pairs \
    --region "$REGION" \
    --filters "Name=key-name,Values=$KEY_NAME" \
    --query 'KeyPairs[0].KeyName' \
    --output text 2>/dev/null)

if [ "$EXISTING_KEY" == "$KEY_NAME" ]; then
    aws ec2 delete-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME"

    # Remove local .pem file if it exists
    if [ -f "${KEY_NAME}.pem" ]; then
        rm -f "${KEY_NAME}.pem"
        log "Removed local key file: ${KEY_NAME}.pem"
    fi

    log "Key pair '$KEY_NAME' deleted."
else
    log "Key pair '$KEY_NAME' not found. Skipping."
fi

# ----------------------------- Delete Security Groups ------------------------
log "Looking for security groups tagged $TAG_KEY=$TAG_VALUE ..."

SG_IDS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'SecurityGroups[*].GroupId' \
    --output text)

if [ -z "$SG_IDS" ]; then
    log "No security groups found."
else
    for SG_ID in $SG_IDS; do
        log "Deleting security group: $SG_ID ..."
        aws ec2 delete-security-group \
            --region "$REGION" \
            --group-id "$SG_ID" && log "Deleted: $SG_ID" \
            || log "Could not delete $SG_ID (may still be attached to an instance). Skipping."
    done
fi

# ----------------------------- Delete S3 Buckets -----------------------------
log "Looking for S3 buckets tagged $TAG_KEY=$TAG_VALUE ..."

ALL_BUCKETS=$(aws s3api list-buckets \
    --query 'Buckets[*].Name' \
    --output text)

for BUCKET in $ALL_BUCKETS; do
    # Check if this bucket has the matching tag
    BUCKET_TAG=$(aws s3api get-bucket-tagging \
        --bucket "$BUCKET" \
        --query "TagSet[?Key=='$TAG_KEY'].Value" \
        --output text 2>/dev/null || echo "")

    if [ "$BUCKET_TAG" == "$TAG_VALUE" ]; then
        log "Found tagged bucket: $BUCKET — emptying and deleting ..."

        # Delete all object versions (required when versioning is enabled)
        aws s3api list-object-versions \
            --bucket "$BUCKET" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
objects = data.get('Objects') or []
if objects:
    delete_payload = json.dumps({'Objects': objects, 'Quiet': True})
    subprocess.run(['aws', 's3api', 'delete-objects',
                    '--bucket', '$BUCKET',
                    '--delete', delete_payload], check=True)
" 2>/dev/null || true

        # Delete all delete markers
        aws s3api list-object-versions \
            --bucket "$BUCKET" \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json 2>/dev/null | \
        python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
objects = data.get('Objects') or []
if objects:
    delete_payload = json.dumps({'Objects': objects, 'Quiet': True})
    subprocess.run(['aws', 's3api', 'delete-objects',
                    '--bucket', '$BUCKET',
                    '--delete', delete_payload], check=True)
" 2>/dev/null || true

        # Delete the now-empty bucket
        aws s3api delete-bucket \
            --bucket "$BUCKET" \
            --region "$REGION"

        log "Bucket '$BUCKET' deleted."
    fi
done

# ----------------------------- Delete VPC Resources --------------------------
log "Looking for AutomationLab VPC ..."

VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    log "No tagged VPC found. Skipping VPC cleanup."
else
    log "Found VPC: $VPC_ID — cleaning up components ..."

    # Detach and delete Internet Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways \
        --region "$REGION" \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[*].InternetGatewayId' \
        --output text)

    for IGW_ID in $IGW_IDS; do
        log "Detaching and deleting Internet Gateway: $IGW_ID ..."
        aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
        aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
    done

    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[*].SubnetId' \
        --output text)

    for SUBNET_ID in $SUBNET_IDS; do
        log "Deleting subnet: $SUBNET_ID ..."
        aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
    done

    # Delete non-main Route Tables
    RT_IDS=$(aws ec2 describe-route-tables \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
        --query 'RouteTables[*].RouteTableId' \
        --output text)

    for RT_ID in $RT_IDS; do
        log "Deleting route table: $RT_ID ..."
        aws ec2 delete-route-table --region "$REGION" --route-table-id "$RT_ID" || \
            log "Could not delete route table $RT_ID (may be the main table). Skipping."
    done

    # Delete the VPC
    log "Deleting VPC: $VPC_ID ..."
    aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
    log "VPC deleted."

    # Remove local config file
    if [ -f "vpc_config.env" ]; then
        rm -f vpc_config.env
        log "Removed vpc_config.env"
    fi
fi

# ----------------------------- Summary ---------------------------------------
echo ""
echo "============================================="
echo "  Cleanup Complete"
echo "============================================="
echo "  All AutomationLab resources have been"
echo "  removed from region: $REGION"
echo "============================================="
echo ""
