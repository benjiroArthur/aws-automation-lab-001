# AutomationLab — AWS CLI Bash Automation Scripts

A set of Bash scripts that automate the provisioning and cleanup of AWS resources (EC2, Security Groups, S3) using the AWS CLI.

---

## Prerequisites

Before running any script, ensure the following are in place:

1. **AWS CLI v2** installed on your machine
   ```bash
   aws --version
   ```

2. **AWS credentials configured** via `aws configure`
   ```bash
   aws configure
   # Provide: Access Key ID, Secret Access Key, Region (eu-north-1), Output format (json)
   ```

3. **Verify your credentials and region**
   ```bash
   aws sts get-caller-identity
   aws configure list
   ```

4. **Make scripts executable**
   ```bash
   chmod +x create_ec2.sh create_security_group.sh create_s3_bucket.sh cleanup_resources.sh
   ```

---

## Scripts

### 1. `create_ec2.sh` — Launch an EC2 Instance

Creates a new EC2 key pair and launches a free-tier Amazon Linux 2 instance tagged with `Project=AutomationLab`.

**Usage:**
```bash
./create_ec2.sh
```

**What it does:**
- Creates a key pair (`automation-lab-key`) and saves it as `automation-lab-key.pem`
- Launches a `t3.micro` Amazon Linux 2 instance in `eu-north-1`
- Tags the instance with `Project=AutomationLab` and `Name=AutomationLab-EC2`
- Waits for the instance to reach the `running` state
- Prints the Instance ID and Public IP

**Sample output:**
```
=============================================
  EC2 Instance Created Successfully
=============================================
  Instance ID : i-0abc123def456789
  Public IP   : 54.123.45.67
  Key File    : automation-lab-key.pem
  Region      : eu-north-1
  Tag         : Project=AutomationLab
=============================================
```

---

### 2. `create_security_group.sh` — Create a Security Group

Creates a security group (`devops-t-model-sg`) with inbound rules for SSH (port 22) and HTTP (port 80).

**Usage:**
```bash
./create_security_group.sh
```

**What it does:**
- Detects your default VPC automatically
- Creates security group `devops-t-model-sg` with a description
- Opens port 22 (SSH) and port 80 (HTTP) from anywhere (`0.0.0.0/0`)
- Tags the group with `Project=AutomationLab`
- Displays all inbound rules in a table

**Sample output:**
```
=============================================
  Security Group Created Successfully
=============================================
  Group Name  : devops-t-model-sg
  Group ID    : sg-0abc123456789
  VPC ID      : vpc-0abc12345
  Region      : eu-north-1
  Tag         : Project=AutomationLab
=============================================
```

---

### 3. `create_s3_bucket.sh` — Create an S3 Bucket

Creates a uniquely named S3 bucket with versioning enabled, a security policy (HTTPS-only), and uploads a sample file.

**Usage:**
```bash
./create_s3_bucket.sh
```

**What it does:**
- Generates a unique bucket name using a timestamp + random suffix
- Creates the bucket in `eu-north-1`
- Enables versioning
- Applies a bucket policy that denies non-HTTPS access
- Tags the bucket with `Project=AutomationLab`
- Uploads `welcome.txt` to the bucket

**Sample output:**
```
=============================================
  S3 Bucket Created Successfully
=============================================
  Bucket Name : automation-lab-20240518123045-12345
  Region      : eu-north-1
  Versioning  : Enabled
  Tag         : Project=AutomationLab
  Uploaded    : s3://automation-lab-20240518123045-12345/welcome.txt
=============================================
```

---

### 4. `cleanup_resources.sh` — Delete All Resources

Safely removes all resources tagged `Project=AutomationLab` to avoid unwanted AWS charges.

**Usage:**
```bash
./cleanup_resources.sh
```

**What it does:**
- Prompts for confirmation before proceeding
- Terminates all tagged EC2 instances and waits for termination
- Deletes the `automation-lab-key` key pair and local `.pem` file
- Deletes all tagged security groups
- Empties and deletes all tagged S3 buckets (handles versioned objects)

---

## Recommended Execution Order

```bash
# 1. Set up security group first (so you can attach it to EC2 if needed)
./create_security_group.sh

# 2. Launch the EC2 instance
./create_ec2.sh

# 3. Create the S3 bucket
./create_s3_bucket.sh

# 4. When done — clean everything up
./cleanup_resources.sh
```

---

## Notes

- All resources are tagged `Project=AutomationLab` so they are easy to identify and safely cleaned up.
- Scripts use `set -euo pipefail` to exit immediately on any error.
- Duplicate resource detection is built in — re-running scripts won't create duplicates.

---
