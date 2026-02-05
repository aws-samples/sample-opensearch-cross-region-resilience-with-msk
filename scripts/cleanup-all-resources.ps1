# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# DISCLAIMER: This code is provided as a reference implementation and is not
# intended for production use without thorough review and customization.
#
# cleanup-all-resources.ps1
# Complete cleanup script for AWS OpenSearch Cross-Region setup

param(
    [string]$EnvironmentName = "production",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "us-west-2",
    [switch]$Force
)

# Color output functions
function Write-Success { param([string]$Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Error { param([string]$Message) Write-Host "✗ $Message" -ForegroundColor Red }
function Write-Warning { param([string]$Message) Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "ℹ $Message" -ForegroundColor Cyan }
function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Blue }

Write-Host "========================================" -ForegroundColor Red
Write-Host "  AWS OpenSearch Cleanup Script" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""
Write-Warning "This will DELETE all resources for environment: $EnvironmentName"
Write-Warning "Regions: $PrimaryRegion, $SecondaryRegion"
Write-Host ""

if (-not $Force) {
    $confirmation = Read-Host "Are you sure you want to continue? Type 'DELETE' to confirm"
    if ($confirmation -ne "DELETE") {
        Write-Info "Cleanup cancelled."
        exit 0
    }
}

# Function to check if stack exists
function Test-StackExists {
    param([string]$StackName, [string]$Region)
    
    try {
        $stack = aws cloudformation describe-stacks `
            --stack-name $StackName `
            --region $Region `
            --query 'Stacks[0].StackStatus' `
            --output text 2>$null
        
        return ($null -ne $stack -and $stack -ne "")
    } catch {
        return $false
    }
}

# Function to empty and delete S3 bucket
function Remove-S3BucketCompletely {
    param([string]$BucketName, [string]$Region)
    
    Write-Info "Checking S3 bucket: $BucketName"
    
    # Check if bucket exists
    $bucketExists = aws s3api head-bucket --bucket $BucketName --region $Region 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Bucket $BucketName does not exist or already deleted"
        return
    }
    
    Write-Info "Emptying S3 bucket: $BucketName"
    
    # Delete all object versions
    aws s3api list-object-versions `
        --bucket $BucketName `
        --region $Region `
        --output json 2>$null | ConvertFrom-Json | ForEach-Object {
        
        # Delete versions
        if ($_.Versions) {
            $_.Versions | ForEach-Object {
                Write-Host "  Deleting version: $($_.Key) ($($_.VersionId))"
                aws s3api delete-object `
                    --bucket $BucketName `
                    --key $_.Key `
                    --version-id $_.VersionId `
                    --region $Region 2>$null
            }
        }
        
        # Delete delete markers
        if ($_.DeleteMarkers) {
            $_.DeleteMarkers | ForEach-Object {
                Write-Host "  Deleting marker: $($_.Key) ($($_.VersionId))"
                aws s3api delete-object `
                    --bucket $BucketName `
                    --key $_.Key `
                    --version-id $_.VersionId `
                    --region $Region 2>$null
            }
        }
    }
    
    # Delete all objects (non-versioned)
    aws s3 rm "s3://$BucketName" --recursive --region $Region 2>$null
    
    # Delete the bucket
    Write-Info "Deleting S3 bucket: $BucketName"
    aws s3api delete-bucket --bucket $BucketName --region $Region 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "S3 bucket deleted: $BucketName"
    } else {
        Write-Warning "Could not delete S3 bucket: $BucketName (may not exist)"
    }
}

# Function to delete CloudFormation stack
function Remove-CloudFormationStack {
    param([string]$StackName, [string]$Region)
    
    if (-not (Test-StackExists -StackName $StackName -Region $Region)) {
        Write-Info "Stack $StackName does not exist in $Region"
        return
    }
    
    Write-Info "Deleting CloudFormation stack: $StackName in $Region"
    
    aws cloudformation delete-stack `
        --stack-name $StackName `
        --region $Region
    
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Waiting for stack deletion: $StackName"
        
        # Wait with timeout
        $timeout = 3600 # 60 minutes
        $elapsed = 0
        $interval = 30
        
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            
            if (-not (Test-StackExists -StackName $StackName -Region $Region)) {
                Write-Success "Stack deleted: $StackName"
                return
            }
            
            $status = aws cloudformation describe-stacks `
                --stack-name $StackName `
                --region $Region `
                --query 'Stacks[0].StackStatus' `
                --output text 2>$null
            
            Write-Host "  Status: $status (${elapsed}s elapsed)"
            
            if ($status -like "*FAILED*") {
                Write-Error "Stack deletion failed: $StackName"
                Write-Warning "Check AWS Console for details"
                return
            }
        }
        
        Write-Warning "Stack deletion timeout: $StackName"
    } else {
        Write-Error "Failed to initiate stack deletion: $StackName"
    }
}

# Main cleanup process
Write-Step "Step 1: Cleaning up S3 Buckets"

# S3 buckets must be emptied before stack deletion
$primaryBucket = "$EnvironmentName-opensearch-dlq-$PrimaryRegion"
$secondaryBucket = "$EnvironmentName-opensearch-dlq-$SecondaryRegion"

Remove-S3BucketCompletely -BucketName $primaryBucket -Region $PrimaryRegion
Remove-S3BucketCompletely -BucketName $secondaryBucket -Region $SecondaryRegion

Write-Step "Step 2: Deleting Secondary Region Application Stack"

Remove-CloudFormationStack `
    -StackName "$EnvironmentName-opensearch-secondary" `
    -Region $SecondaryRegion

Write-Step "Step 3: Deleting Primary Region Application Stack"

Remove-CloudFormationStack `
    -StackName "$EnvironmentName-opensearch-primary" `
    -Region $PrimaryRegion

Write-Step "Step 4: Deleting VPC Stacks"

# Delete VPC stacks (if they exist)
Remove-CloudFormationStack `
    -StackName "$EnvironmentName-vpc-secondary" `
    -Region $SecondaryRegion

Remove-CloudFormationStack `
    -StackName "$EnvironmentName-vpc-primary" `
    -Region $PrimaryRegion

Write-Step "Step 5: Verifying Cleanup"

# Check for any remaining resources
Write-Info "Checking for remaining CloudFormation stacks..."

$remainingStacks = @()

$primaryStacks = aws cloudformation list-stacks `
    --region $PrimaryRegion `
    --query "StackSummaries[?starts_with(StackName, '$EnvironmentName') && StackStatus != 'DELETE_COMPLETE'].StackName" `
    --output text 2>$null

$secondaryStacks = aws cloudformation list-stacks `
    --region $SecondaryRegion `
    --query "StackSummaries[?starts_with(StackName, '$EnvironmentName') && StackStatus != 'DELETE_COMPLETE'].StackName" `
    --output text 2>$null

if ($primaryStacks) { $remainingStacks += $primaryStacks }
if ($secondaryStacks) { $remainingStacks += $secondaryStacks }

if ($remainingStacks.Count -gt 0) {
    Write-Warning "Some stacks still exist:"
    $remainingStacks | ForEach-Object { Write-Host "  - $_" }
    Write-Info "These may still be deleting. Check AWS Console for status."
} else {
    Write-Success "All CloudFormation stacks deleted!"
}

# Check for orphaned resources
Write-Info "`nChecking for potential orphaned resources..."

Write-Info "Checking S3 buckets..."
$s3Buckets = aws s3api list-buckets `
    --query "Buckets[?contains(Name, '$EnvironmentName')].Name" `
    --output text 2>$null

if ($s3Buckets) {
    Write-Warning "Found S3 buckets that may need manual deletion:"
    $s3Buckets -split "`t" | ForEach-Object { Write-Host "  - $_" }
}

Write-Info "Checking CloudWatch Log Groups..."
$logGroups = aws logs describe-log-groups `
    --region $PrimaryRegion `
    --query "logGroups[?contains(logGroupName, '$EnvironmentName')].logGroupName" `
    --output text 2>$null

if ($logGroups) {
    Write-Warning "Found CloudWatch Log Groups that may need manual deletion:"
    $logGroups -split "`t" | ForEach-Object { Write-Host "  - $_" }
}

Write-Step "Cleanup Summary"

Write-Host ""
Write-Success "Cleanup process completed!"
Write-Host ""
Write-Info "What was deleted:"
Write-Host "  ✓ Application stacks (MSK, OSI, OpenSearch)"
Write-Host "  ✓ VPC infrastructure stacks"
Write-Host "  ✓ S3 DLQ buckets"
Write-Host ""
Write-Info "What may still exist:"
Write-Host "  • KMS keys (pending deletion for 7-30 days)"
Write-Host "  • CloudWatch Logs (if retention is set)"
Write-Host "  • Any manually created resources"
Write-Host ""
Write-Info "Next steps:"
Write-Host "  1. Check AWS Console to verify all resources are deleted"
Write-Host "  2. Review AWS Cost Explorer for any remaining charges"
Write-Host "  3. Check for any orphaned resources listed above"
Write-Host ""
Write-Warning "Note: Some resources like KMS keys have mandatory deletion waiting periods"
Write-Host ""
