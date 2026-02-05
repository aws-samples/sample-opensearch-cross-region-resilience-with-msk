# Cleanup Guide - Deleting All Resources

## Quick Answer

**Yes, deleting CloudFormation stacks will delete most resources**, but you need to:
1. **Empty S3 buckets first** (they won't delete if they contain objects)
2. **Delete in the correct order** (application stacks before VPC stacks)
3. **Be aware of resources with deletion delays** (KMS keys)

## 🚀 Quick Cleanup (Automated)

Use the provided cleanup script:

```powershell
# Run the automated cleanup script
.\scripts\cleanup-all-resources.ps1 `
  -EnvironmentName "production" `
  -PrimaryRegion "us-east-1" `
  -SecondaryRegion "us-west-2"

# Or with force flag (no confirmation prompt)
.\scripts\cleanup-all-resources.ps1 -Force
```

This script will:
- ✓ Empty and delete S3 buckets
- ✓ Delete application stacks in correct order
- ✓ Delete VPC stacks
- ✓ Verify cleanup completion
- ✓ Report any remaining resources

## 📋 Manual Cleanup (Step-by-Step)

### Step 1: Empty S3 Buckets (CRITICAL!)

S3 buckets **must be empty** before CloudFormation can delete them:

```powershell
# Empty and delete primary region DLQ bucket
aws s3 rm "s3://production-opensearch-dlq-us-east-1" --recursive --region us-east-1
aws s3 rb "s3://production-opensearch-dlq-us-east-1" --region us-east-1

# Empty and delete secondary region DLQ bucket
aws s3 rm "s3://production-opensearch-dlq-us-west-2" --recursive --region us-west-2
aws s3 rb "s3://production-opensearch-dlq-us-west-2" --region us-west-2
```

**Why this is needed:**
- CloudFormation cannot delete non-empty S3 buckets
- Stack deletion will fail with error: "The bucket you tried to delete is not empty"
- You must manually empty buckets first

### Step 2: Delete Application Stacks

Delete application stacks **before** VPC stacks (they depend on VPCs):

```powershell
# Delete secondary region application stack
aws cloudformation delete-stack `
  --stack-name production-opensearch-secondary `
  --region us-west-2

# Wait for deletion to complete
aws cloudformation wait stack-delete-complete `
  --stack-name production-opensearch-secondary `
  --region us-west-2

Write-Host "✓ Secondary application stack deleted" -ForegroundColor Green

# Delete primary region application stack
aws cloudformation delete-stack `
  --stack-name production-opensearch-primary `
  --region us-east-1

# Wait for deletion to complete
aws cloudformation wait stack-delete-complete `
  --stack-name production-opensearch-primary `
  --region us-east-1

Write-Host "✓ Primary application stack deleted" -ForegroundColor Green
```

**What gets deleted:**
- MSK clusters (all brokers)
- MSK Replicator
- OpenSearch Serverless collections
- OpenSearch Ingestion pipelines
- Security Groups
- IAM Roles and Policies
- CloudWatch Log Groups
- VPC Endpoints
- KMS Keys (scheduled for deletion)

**Time:** 15-30 minutes per stack

### Step 3: Delete VPC Stacks (If Created)

Only if you created VPCs using the vpc-infrastructure template:

```powershell
# Delete secondary region VPC stack
aws cloudformation delete-stack `
  --stack-name production-vpc-secondary `
  --region us-west-2

# Wait for deletion
aws cloudformation wait stack-delete-complete `
  --stack-name production-vpc-secondary `
  --region us-west-2

Write-Host "✓ Secondary VPC stack deleted" -ForegroundColor Green

# Delete primary region VPC stack
aws cloudformation delete-stack `
  --stack-name production-vpc-primary `
  --region us-east-1

# Wait for deletion
aws cloudformation wait stack-delete-complete `
  --stack-name production-vpc-primary `
  --region us-east-1

Write-Host "✓ Primary VPC stack deleted" -ForegroundColor Green
```

**What gets deleted:**
- VPCs
- Subnets (public and private)
- Internet Gateways
- NAT Gateways
- Elastic IPs
- Route Tables
- VPC Flow Logs

**Time:** 5-10 minutes per stack

### Step 4: Verify Cleanup

```powershell
# Check for remaining stacks
aws cloudformation list-stacks `
  --region us-east-1 `
  --query "StackSummaries[?starts_with(StackName, 'production') && StackStatus != 'DELETE_COMPLETE']" `
  --output table

aws cloudformation list-stacks `
  --region us-west-2 `
  --query "StackSummaries[?starts_with(StackName, 'production') && StackStatus != 'DELETE_COMPLETE']" `
  --output table

# Check for remaining S3 buckets
aws s3 ls | Select-String "production"

# Check for remaining CloudWatch Log Groups
aws logs describe-log-groups `
  --region us-east-1 `
  --query "logGroups[?contains(logGroupName, 'production')]" `
  --output table
```

## ⚠️ Resources That Need Special Attention

### 1. S3 Buckets (Most Common Issue)

**Problem:** Buckets with objects won't delete

**Solution:**
```powershell
# For versioned buckets, delete all versions
aws s3api list-object-versions `
  --bucket production-opensearch-dlq-us-east-1 `
  --output json | ConvertFrom-Json | ForEach-Object {
    $_.Versions | ForEach-Object {
        aws s3api delete-object `
          --bucket production-opensearch-dlq-us-east-1 `
          --key $_.Key `
          --version-id $_.VersionId
    }
}

# Then delete the bucket
aws s3 rb s3://production-opensearch-dlq-us-east-1 --force
```

### 2. KMS Keys

**Behavior:** KMS keys have a mandatory waiting period (7-30 days)

**What happens:**
- Stack deletion schedules the key for deletion
- Key enters "PendingDeletion" state
- Actual deletion happens after waiting period
- You can cancel deletion during this period

**Check KMS key status:**
```powershell
aws kms list-keys --region us-east-1 --output table

aws kms describe-key `
  --key-id <KEY_ID> `
  --region us-east-1 `
  --query 'KeyMetadata.KeyState'
```

**Cancel deletion (if needed):**
```powershell
aws kms cancel-key-deletion --key-id <KEY_ID> --region us-east-1
```

### 3. CloudWatch Logs

**Behavior:** Log groups are deleted, but:
- Logs may be retained based on retention policy
- Archived logs in S3 remain
- Metric filters are deleted

**Manual deletion (if needed):**
```powershell
aws logs delete-log-group `
  --log-group-name /aws/msk/production-primary `
  --region us-east-1
```

### 4. Cross-Stack Dependencies

**Problem:** Stack deletion fails with "Export cannot be deleted as it is in use"

**Solution:** Delete dependent stacks first
```powershell
# Always delete in this order:
# 1. Application stacks (depend on VPC)
# 2. VPC stacks (provide exports)
```

## 🔍 Troubleshooting Deletion Issues

### Issue 1: Stack Deletion Stuck

**Symptoms:** Stack shows "DELETE_IN_PROGRESS" for a long time

**Solutions:**
```powershell
# Check stack events for errors
aws cloudformation describe-stack-events `
  --stack-name production-opensearch-primary `
  --region us-east-1 `
  --max-items 20 `
  --output table

# Look for resources that failed to delete
aws cloudformation describe-stack-resources `
  --stack-name production-opensearch-primary `
  --region us-east-1 `
  --query "StackResources[?ResourceStatus=='DELETE_FAILED']" `
  --output table
```

**Common causes:**
- S3 bucket not empty
- Resource in use by another service
- IAM role still attached to resources
- Security group still attached to network interfaces

### Issue 2: "Resource Being Used" Error

**Symptoms:** Deletion fails with "resource is being used by another resource"

**Solutions:**
```powershell
# For Security Groups
aws ec2 describe-network-interfaces `
  --filters "Name=group-id,Values=sg-xxxxx" `
  --region us-east-1

# For VPCs
aws ec2 describe-vpc-peering-connections `
  --filters "Name=requester-vpc-info.vpc-id,Values=vpc-xxxxx" `
  --region us-east-1
```

### Issue 3: Stack Deletion Failed

**Symptoms:** Stack shows "DELETE_FAILED" status

**Solutions:**
```powershell
# Skip failed resources and continue deletion
aws cloudformation delete-stack `
  --stack-name production-opensearch-primary `
  --region us-east-1 `
  --retain-resources <RESOURCE_LOGICAL_ID>

# Or manually delete the problematic resource first
# Then retry stack deletion
```

## 💰 Cost Verification After Cleanup

### Check for Remaining Charges

```powershell
# View recent costs (requires Cost Explorer API access)
aws ce get-cost-and-usage `
  --time-period Start=2024-01-01,End=2024-01-31 `
  --granularity DAILY `
  --metrics BlendedCost `
  --group-by Type=SERVICE

# Check for running resources
aws resourcegroupstaggingapi get-resources `
  --tag-filters Key=Environment,Values=production `
  --region us-east-1
```

### Common Sources of Unexpected Costs

1. **NAT Gateway** - Charged hourly even if idle
2. **Elastic IPs** - Charged if not attached to running instances
3. **EBS Volumes** - Snapshots may remain
4. **CloudWatch Logs** - Data storage charges
5. **S3 Storage** - Objects in buckets
6. **KMS Keys** - Pending deletion keys still incur charges

## 📊 Cleanup Checklist

Use this checklist to ensure complete cleanup:

### Pre-Deletion
- [ ] Backup any important data from OpenSearch
- [ ] Export any CloudWatch metrics or logs you need
- [ ] Document current configuration for future reference
- [ ] Notify team members about the deletion

### Deletion Process
- [ ] Empty all S3 buckets
- [ ] Delete secondary application stack
- [ ] Wait for secondary stack deletion to complete
- [ ] Delete primary application stack
- [ ] Wait for primary stack deletion to complete
- [ ] Delete secondary VPC stack (if created)
- [ ] Delete primary VPC stack (if created)

### Post-Deletion Verification
- [ ] Verify all CloudFormation stacks are deleted
- [ ] Check for remaining S3 buckets
- [ ] Check for remaining CloudWatch Log Groups
- [ ] Verify no orphaned Security Groups
- [ ] Check for remaining Elastic IPs
- [ ] Verify KMS keys are scheduled for deletion
- [ ] Review AWS Cost Explorer for any remaining charges
- [ ] Check for any manual resources created outside CloudFormation

### 30 Days Later
- [ ] Verify KMS keys are fully deleted
- [ ] Confirm no unexpected charges in billing
- [ ] Remove any saved configurations or credentials

## 🎯 Quick Reference Commands

### Check Stack Status
```powershell
aws cloudformation describe-stacks --stack-name <STACK_NAME> --region <REGION>
```

### Force Delete Stack (Skip Failed Resources)
```powershell
aws cloudformation delete-stack --stack-name <STACK_NAME> --retain-resources <RESOURCE_ID>
```

### List All Stacks
```powershell
aws cloudformation list-stacks --region <REGION> --output table
```

### Empty S3 Bucket
```powershell
aws s3 rm s3://<BUCKET_NAME> --recursive
```

### Delete S3 Bucket
```powershell
aws s3 rb s3://<BUCKET_NAME> --force
```

## 📞 Getting Help

If you encounter issues during cleanup:

1. **Check CloudFormation Events**
   ```powershell
   aws cloudformation describe-stack-events --stack-name <STACK_NAME>
   ```

2. **Review AWS Console**
   - CloudFormation → Stacks → Events tab
   - Look for DELETE_FAILED resources

3. **AWS Support**
   - Open a support case if you have AWS Support plan
   - Provide stack name and error messages

4. **Manual Resource Deletion**
   - As a last resort, manually delete resources via AWS Console
   - Then delete the stack with `--retain-resources` flag

## Summary

**Key Points:**
- ✅ CloudFormation deletes most resources automatically
- ⚠️ S3 buckets must be emptied first
- ⚠️ Delete in correct order (applications before VPCs)
- ⚠️ KMS keys have 7-30 day deletion waiting period
- ✅ Use the automated cleanup script for easiest cleanup
- ✅ Always verify cleanup completion

**Estimated Cleanup Time:**
- Automated script: 30-60 minutes
- Manual cleanup: 45-90 minutes

**Cost After Cleanup:**
- Most resources: $0 immediately
- KMS keys: Charged until deletion completes (7-30 days)
- S3 storage: $0 after buckets are deleted
