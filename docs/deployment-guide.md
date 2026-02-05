# Cross-Region Active-Active OpenSearch Deployment Guide

This guide walks you through deploying a cross-region active-active OpenSearch architecture using MSK for data streaming and OSI (OpenSearch Ingestion) pipelines.

## Architecture Overview

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────────┐
│         PRIMARY (us-east-1)         │     │        SECONDARY (us-west-2)        │
│                                     │     │                                     │
│  ┌─────────┐    ┌───────────────┐   │     │   ┌───────────────┐    ┌─────────┐  │
│  │ Producer│───▶│  MSK Cluster  │◀──┼─────┼──▶│  MSK Cluster  │◀───│Producer │  │
│  └─────────┘    └───────┬───────┘   │     │   └───────┬───────┘    └─────────┘  │
│                         │           │     │           │                         │
│                         ▼           │     │           ▼                         │
│                 ┌───────────────┐   │     │   ┌───────────────┐                 │
│                 │ OSI Pipeline  │   │     │   │ OSI Pipeline  │                 │
│                 └───────┬───────┘   │     │   └───────┬───────┘                 │
│                         │           │     │           │                         │
│                         ▼           │     │           ▼                         │
│                 ┌───────────────┐   │     │   ┌───────────────┐                 │
│                 │  OpenSearch   │   │     │   │  OpenSearch   │                 │
│                 │  Serverless   │   │     │   │  Serverless   │                 │
│                 └───────────────┘   │     │   └───────────────┘                 │
└─────────────────────────────────────┘     └─────────────────────────────────────┘
                         │                               │
                         │◀──────────────────────────────│
                         │   MSK Replicator (Bidirectional)
                         │──────────────────────────────▶│
```

## Active-Active Replication

For true active-active setup, we deploy **two MSK Replicators**:
1. **Primary → Secondary**: Replicates data written to us-east-1 to us-west-2
2. **Secondary → Primary**: Replicates data written to us-west-2 to us-east-1

Both replicators use **IDENTICAL topic naming** mode, which:
- Keeps the same topic name (`opensearch-data`) in both regions
- Uses Kafka headers to prevent infinite replication loops
- Simplifies consumer configuration (no wildcard patterns needed)

## Prerequisites

- AWS CLI configured with appropriate permissions
- Two AWS regions (default: us-east-1 and us-west-2)
- PowerShell (for Windows) or Bash (for Linux/Mac)

## Resource Creation Times

Based on our deployment experience, here are the expected wait times:

| Resource | Creation Time | Update Time |
|----------|--------------|-------------|
| VPC Infrastructure | ~10 minutes | N/A |
| MSK Cluster | 25-35 minutes | N/A |
| Multi-VPC Connectivity | 15-25 minutes | N/A |
| OpenSearch Collection | 2-3 minutes | N/A |
| OSI Pipeline | 5-10 minutes | N/A |
| MSK Replicator (each) | 15-30 minutes | N/A |

## Deployment Steps

### Step 1: Deploy VPC Infrastructure (Both Regions)

```powershell
# Primary Region (us-east-1)
aws cloudformation create-stack `
  --stack-name production-vpc-primary `
  --template-body file://cloudformation/vpc-infrastructure.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
  --region us-east-1 `
  --capabilities CAPABILITY_NAMED_IAM

# Secondary Region (us-west-2) - Use different CIDR
aws cloudformation create-stack `
  --stack-name production-vpc-secondary `
  --template-body file://cloudformation/vpc-infrastructure.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=VpcCIDR,ParameterValue=10.1.0.0/16 `
  --region us-west-2 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (~10 minutes each)
aws cloudformation wait stack-create-complete --stack-name production-vpc-primary --region us-east-1
aws cloudformation wait stack-create-complete --stack-name production-vpc-secondary --region us-west-2
```

### Step 2: Deploy Primary Region (Phase 1 - MSK Only)

Deploy without OSI pipeline first. MSK cluster takes 25-35 minutes to create.

```powershell
aws cloudformation create-stack `
  --stack-name production-opensearch-primary `
  --template-body file://cloudformation/primary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=UseExistingVPC,ParameterValue=false `
               ParameterKey=DeployOSIPipeline,ParameterValue=false `
  --region us-east-1 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (25-35 minutes)
aws cloudformation wait stack-create-complete --stack-name production-opensearch-primary --region us-east-1
```

### Step 3: Enable Multi-VPC Connectivity on Primary MSK

OSI requires multi-VPC connectivity to connect to MSK. This takes 15-25 minutes.

```powershell
# Get MSK cluster ARN
$MSK_ARN = aws cloudformation describe-stacks `
  --stack-name production-opensearch-primary `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" `
  --output text

# Get current version
$CURRENT_VERSION = aws kafka describe-cluster `
  --cluster-arn $MSK_ARN `
  --query "ClusterInfo.CurrentVersion" `
  --output text `
  --region us-east-1

# Enable multi-VPC connectivity (15-25 minutes)
aws kafka update-connectivity `
  --cluster-arn $MSK_ARN `
  --current-version $CURRENT_VERSION `
  --connectivity-info '{"VpcConnectivity":{"ClientAuthentication":{"Sasl":{"Iam":{"Enabled":true}}}}}' `
  --region us-east-1

# Wait for MSK to return to ACTIVE state
do {
    Start-Sleep -Seconds 30
    $state = aws kafka describe-cluster --cluster-arn $MSK_ARN --query "ClusterInfo.State" --output text --region us-east-1
    Write-Host "MSK State: $state"
} while ($state -ne "ACTIVE")
```

### Step 4: Deploy Primary Region (Phase 2 - Add OSI Pipeline)

```powershell
aws cloudformation update-stack `
  --stack-name production-opensearch-primary `
  --template-body file://cloudformation/primary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=UseExistingVPC,ParameterValue=false `
               ParameterKey=DeployOSIPipeline,ParameterValue=true `
  --region us-east-1 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (5-10 minutes for OSI pipeline)
aws cloudformation wait stack-update-complete --stack-name production-opensearch-primary --region us-east-1
```

### Step 5: Deploy Secondary Region (Phase 1 - MSK Only)

```powershell
# Get Primary MSK ARN
$PRIMARY_MSK_ARN = aws cloudformation describe-stacks `
  --stack-name production-opensearch-primary `
  --region us-east-1 `
  --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" `
  --output text

# Deploy secondary (without replicator initially to avoid timeout)
aws cloudformation create-stack `
  --stack-name production-opensearch-secondary `
  --template-body file://cloudformation/secondary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=UseExistingVPC,ParameterValue=false `
               ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
               ParameterKey=DeployOSIPipeline,ParameterValue=false `
               ParameterKey=DeployMSKReplicator,ParameterValue=false `
  --region us-west-2 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (25-35 minutes)
aws cloudformation wait stack-create-complete --stack-name production-opensearch-secondary --region us-west-2
```

### Step 6: Enable Multi-VPC Connectivity on Secondary MSK

```powershell
# Get secondary MSK ARN
$SECONDARY_MSK_ARN = aws cloudformation describe-stacks `
  --stack-name production-opensearch-secondary `
  --region us-west-2 `
  --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" `
  --output text

# Get current version
$CURRENT_VERSION = aws kafka describe-cluster `
  --cluster-arn $SECONDARY_MSK_ARN `
  --query "ClusterInfo.CurrentVersion" `
  --output text `
  --region us-west-2

# Enable multi-VPC connectivity (15-25 minutes)
aws kafka update-connectivity `
  --cluster-arn $SECONDARY_MSK_ARN `
  --current-version $CURRENT_VERSION `
  --connectivity-info '{"VpcConnectivity":{"ClientAuthentication":{"Sasl":{"Iam":{"Enabled":true}}}}}' `
  --region us-west-2

# Wait for MSK to return to ACTIVE state
do {
    Start-Sleep -Seconds 30
    $state = aws kafka describe-cluster --cluster-arn $SECONDARY_MSK_ARN --query "ClusterInfo.State" --output text --region us-west-2
    Write-Host "MSK State: $state"
} while ($state -ne "ACTIVE")
```

### Step 7: Deploy Secondary Region (Phase 2 - Add OSI Pipeline)

```powershell
aws cloudformation update-stack `
  --stack-name production-opensearch-secondary `
  --template-body file://cloudformation/secondary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=UseExistingVPC,ParameterValue=false `
               ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
               ParameterKey=DeployOSIPipeline,ParameterValue=true `
               ParameterKey=DeployMSKReplicator,ParameterValue=false `
  --region us-west-2 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (5-10 minutes)
aws cloudformation wait stack-update-complete --stack-name production-opensearch-secondary --region us-west-2
```

### Step 8: Deploy MSK Replicator (Optional)

MSK Replicator enables cross-region data replication. Deploy it separately to avoid CloudFormation timeout issues.

**IMPORTANT:** For cross-region replication, each MSK cluster needs VPC configuration from its own region. You must provide the primary region's subnet IDs and security group ID.

```powershell
# Get primary region VPC info
$PRIMARY_SUBNETS = @(
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1'].OutputValue" --output text),
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2'].OutputValue" --output text),
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet3'].OutputValue" --output text)
) -join ","

$PRIMARY_SG = aws cloudformation describe-stacks --stack-name production-opensearch-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='MSKSecurityGroupId'].OutputValue" --output text

# Deploy with primary region VPC parameters
aws cloudformation update-stack `
  --stack-name production-opensearch-secondary `
  --template-body file://cloudformation/secondary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
               ParameterKey=UseExistingVPC,ParameterValue=false `
               ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
               ParameterKey=PrimaryPrivateSubnetIds,ParameterValue="$PRIMARY_SUBNETS" `
               ParameterKey=PrimaryMSKSecurityGroupId,ParameterValue=$PRIMARY_SG `
               ParameterKey=DeployOSIPipeline,ParameterValue=true `
               ParameterKey=DeployMSKReplicator,ParameterValue=true `
  --region us-west-2 `
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (10-20 minutes for replicator)
aws cloudformation wait stack-update-complete --stack-name production-opensearch-secondary --region us-west-2
```

**Alternative: Deploy via CLI (if CloudFormation times out)**

If CloudFormation times out, you can create the MSK Replicator directly via CLI:

```powershell
# Get subnet and security group IDs for both regions
$PRIMARY_SUBNETS = @("subnet-xxx", "subnet-yyy", "subnet-zzz")  # From us-east-1
$PRIMARY_SG = "sg-xxx"  # From us-east-1
$SECONDARY_SUBNETS = @("subnet-aaa", "subnet-bbb", "subnet-ccc")  # From us-west-2
$SECONDARY_SG = "sg-aaa"  # From us-west-2

# Create JSON config files and use aws kafka create-replicator
# See scripts/deploy-all.ps1 for full example
```

## Key Configuration Details

### MSK Cluster Policy

The templates include an `MSKClusterPolicy` that grants both OSI and MSK Replicator permission to connect:

```yaml
MSKClusterPolicy:
  Type: AWS::MSK::ClusterPolicy
  Properties:
    ClusterArn: !Ref MSKCluster
    Policy:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Service: osis-pipelines.amazonaws.com
          Action:
            - 'kafka:CreateVpcConnection'
            - 'kafka:GetBootstrapBrokers'
            - 'kafka:DescribeCluster'
            - 'kafka:DescribeClusterV2'
          Resource: !Ref MSKCluster
        - Effect: Allow
          Principal:
            Service: kafka.amazonaws.com
          Action:
            - 'kafka:CreateVpcConnection'
            - 'kafka:GetBootstrapBrokers'
            - 'kafka:DescribeCluster'
            - 'kafka:DescribeClusterV2'
          Resource: !Ref MSKCluster
```

### Auto-Create Topics

MSK is configured with `auto.create.topics.enable=true` to allow OSI to automatically create topics.

### Two-Phase Deployment

The deployment uses parameters to control resource creation:
- `DeployOSIPipeline`: Controls OSI pipeline deployment
- `DeployMSKReplicator`: Controls MSK Replicator deployment (secondary only)

This is required because:
1. OSI needs multi-VPC connectivity, which cannot be enabled at MSK creation time
2. MSK Replicator can timeout in CloudFormation if deployed with other resources

## Verification

### Check All Resources

```powershell
Write-Host "=== Primary Region (us-east-1) ===" -ForegroundColor Cyan
aws kafka list-clusters --region us-east-1 --query "ClusterInfoList[].{Name:ClusterName,State:State}" --output table
aws opensearchserverless list-collections --region us-east-1 --query "collectionSummaries[].{Name:name,Status:status}" --output table
aws osis list-pipelines --region us-east-1 --query "Pipelines[].{Name:PipelineName,Status:Status}" --output table

Write-Host "`n=== Secondary Region (us-west-2) ===" -ForegroundColor Cyan
aws kafka list-clusters --region us-west-2 --query "ClusterInfoList[].{Name:ClusterName,State:State}" --output table
aws opensearchserverless list-collections --region us-west-2 --query "collectionSummaries[].{Name:name,Status:status}" --output table
aws osis list-pipelines --region us-west-2 --query "Pipelines[].{Name:PipelineName,Status:Status}" --output table

Write-Host "`n=== MSK Replicator ===" -ForegroundColor Cyan
aws kafka list-replicators --region us-west-2 --query "Replicators[].{Name:ReplicatorName,State:ReplicatorState}" --output table
```

## Estimated Total Deployment Time

| Phase | Duration |
|-------|----------|
| VPCs (parallel) | ~10 minutes |
| Primary MSK + OpenSearch | ~35 minutes |
| Primary Multi-VPC Connectivity | ~20 minutes |
| Primary OSI Pipeline | ~10 minutes |
| Secondary MSK + OpenSearch | ~35 minutes |
| Secondary Multi-VPC Connectivity | ~20 minutes |
| Secondary OSI Pipeline | ~10 minutes |
| MSK Replicator (optional) | ~15-30 minutes |
| **Total** | **~2.5-3.5 hours** |

## Troubleshooting

### OSI Pipeline Fails with "Internal Exception"

1. Ensure the MSK cluster policy includes OSI permissions
2. Verify multi-VPC connectivity is enabled on MSK
3. Check that the log group exists: `/aws/vendedlogs/osis/<pipeline-name>`

### OSI Pipeline Fails with "Multi-VPC Connectivity" Error

Enable multi-VPC connectivity on the MSK cluster before deploying OSI:
```powershell
aws kafka update-connectivity --cluster-arn <MSK_ARN> --current-version <VERSION> `
  --connectivity-info '{"VpcConnectivity":{"ClientAuthentication":{"Sasl":{"Iam":{"Enabled":true}}}}}'
```

### MSK Replicator Fails to Stabilize

1. Ensure primary MSK cluster policy allows `kafka.amazonaws.com` service
2. Deploy replicator separately (not with other resources)
3. Use `.*` instead of `*` for consumer group patterns (must be valid regex)

### MSK Replicator Fails with "InvalidVpcConfig" or "Subnets don't exist"

**Root Cause:** For cross-region MSK Replicator, each cluster needs VPC configuration from its own region. You cannot use secondary region subnets for the primary cluster.

**Solution:** Provide the primary region's subnet IDs and security group ID via the `PrimaryPrivateSubnetIds` and `PrimaryMSKSecurityGroupId` parameters:

```powershell
# Get primary region VPC info
$PRIMARY_SUBNETS = @(
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1'].OutputValue" --output text),
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2'].OutputValue" --output text),
    (aws cloudformation describe-stacks --stack-name production-vpc-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet3'].OutputValue" --output text)
) -join ","

$PRIMARY_SG = aws cloudformation describe-stacks --stack-name production-opensearch-primary --region us-east-1 --query "Stacks[0].Outputs[?OutputKey=='MSKSecurityGroupId'].OutputValue" --output text

# Then include these in your CloudFormation parameters
```

### CloudFormation Stack Stuck in UPDATE_IN_PROGRESS

MSK operations can take 15-30 minutes. Check the operation status:
```powershell
aws kafka list-cluster-operations --cluster-arn <MSK_ARN> --region <REGION> --max-results 1
```

## Testing with Lambda

After deployment, use Lambda functions to test the active-active configuration. This serverless approach eliminates the need for EC2 instances.

### Deploy Lambda Test Producer

```powershell
# Create Lambda layer with Kafka dependencies (if not already created)
New-Item -ItemType Directory -Path "lambda-layer/python" -Force
pip install kafka-python aws-msk-iam-sasl-signer-python -t lambda-layer/python
Compress-Archive -Path "lambda-layer/python" -DestinationPath "kafka-layer.zip" -Force

# Publish layer to both regions
aws lambda publish-layer-version --layer-name kafka-msk-layer --zip-file fileb://kafka-layer.zip --compatible-runtimes python3.11 python3.12 --region us-east-1
aws lambda publish-layer-version --layer-name kafka-msk-layer --zip-file fileb://kafka-layer.zip --compatible-runtimes python3.11 python3.12 --region us-west-2
```

See `scripts/lambda/msk_producer.py` for the Lambda function code and `MSK-Blog-Specific.md` for complete deployment instructions.

### Run Tests

```powershell
# Test Primary Region
aws lambda invoke --function-name msk-test-producer --region us-east-1 --cli-binary-format raw-in-base64-out --payload '{"count":20}' response.json
Get-Content response.json

# Test Secondary Region
aws lambda invoke --function-name msk-test-producer --region us-west-2 --cli-binary-format raw-in-base64-out --payload '{"count":20}' response.json
Get-Content response.json
```

### Verify Replication

After sending messages, verify data appears in both OpenSearch collections:
- Primary: Messages from us-east-1 (direct) + us-west-2 (replicated via MSK Replicator)
- Secondary: Messages from us-west-2 (direct) + us-east-1 (replicated via MSK Replicator)

## Cleanup

Delete resources in reverse order:

```powershell
# Delete secondary region first
aws cloudformation delete-stack --stack-name production-opensearch-secondary --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name production-opensearch-secondary --region us-west-2

# Delete primary region
aws cloudformation delete-stack --stack-name production-opensearch-primary --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name production-opensearch-primary --region us-east-1

# Delete VPCs
aws cloudformation delete-stack --stack-name production-vpc-secondary --region us-west-2
aws cloudformation delete-stack --stack-name production-vpc-primary --region us-east-1
```
