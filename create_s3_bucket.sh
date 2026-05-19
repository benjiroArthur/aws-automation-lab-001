#!/bin/bash
# =============================================================================
# Creates a uniquely named S3 bucket, enables versioning, applies a bucket
# policy, and uploads a sample welcome.txt file.
# =============================================================================

set -euo pipefail

# ----------------------------- Configuration ---------------------------------
REGION="us-east-1"
# Unique bucket name using timestamp and a random suffix
BUCKET_NAME="automation-lab-$(date +%Y%m%d%H%M%S)-$RANDOM"
TAG_KEY="Project"
TAG_VALUE="AutomationLab"
SAMPLE_FILE="welcome.txt"

# ----------------------------- Functions -------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    echo "[ERROR] $1" >&2
    exit 1
}

# ----------------------------- Create Sample File ----------------------------
log "Creating sample file: $SAMPLE_FILE ..."

cat > "$SAMPLE_FILE" <<EOF
Welcome to the AutomationLab S3 Bucket!
========================================
This file was uploaded automatically by create_s3_bucket.sh

Bucket : $BUCKET_NAME
Region : $REGION
Date   : $(date)
EOF

log "Sample file created."

# ----------------------------- Create S3 Bucket ------------------------------
log "Creating S3 bucket: $BUCKET_NAME ..."

# Note: us-east-1 does NOT use LocationConstraint — other regions require it
if [ "$REGION" == "us-east-1" ]; then
    # us-east-1 does NOT accept LocationConstraint
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION"
else
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
fi

log "Bucket '$BUCKET_NAME' created."

# ----------------------------- Tag the Bucket --------------------------------
aws s3api put-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --tagging "TagSet=[{Key=$TAG_KEY,Value=$TAG_VALUE}]"

log "Tags applied to bucket."

# ----------------------------- Enable Versioning -----------------------------
log "Enabling versioning on bucket ..."

aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

log "Versioning enabled."

# ----------------------------- Apply Bucket Policy ---------------------------
log "Applying bucket policy (deny non-HTTPS access) ..."

BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonHTTPS",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
EOF
)

aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME" \
    --policy "$BUCKET_POLICY"

log "Bucket policy applied."

# ----------------------------- Upload Sample File ----------------------------
log "Uploading $SAMPLE_FILE to s3://$BUCKET_NAME/ ..."

aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/$SAMPLE_FILE"

log "File uploaded successfully."

# Clean up local sample file
rm -f "$SAMPLE_FILE"

# ----------------------------- Summary ---------------------------------------
VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --query 'Status' \
    --output text)

echo ""
echo "============================================="
echo "  S3 Bucket Created Successfully"
echo "============================================="
echo "  Bucket Name : $BUCKET_NAME"
echo "  Region      : $REGION"
echo "  Versioning  : $VERSIONING_STATUS"
echo "  Tag         : $TAG_KEY=$TAG_VALUE"
echo "  Uploaded    : s3://$BUCKET_NAME/$SAMPLE_FILE"
echo "============================================="
echo ""
log "To list bucket contents:"
echo "  aws s3 ls s3://$BUCKET_NAME/"
