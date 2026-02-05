# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# DISCLAIMER: This code is provided as a reference implementation and is not
# intended for production use without thorough review and customization.
# Review IAM policies and security configurations to ensure they meet your
# organization's security requirements.
#
# Cross-Region Active-Active OpenSearch Deployment Script
# This script deploys the complete infrastructure in both regions
#
# ESTIMATED DEPLOYMENT TIMES:
# - VPC Infrastructure: ~10 minutes per region
# - MSK Cluster: 25-35 minutes per region
# - Multi-VPC Connectivity: 15-25 minutes per region
# - OSI Pipeline: 5-10 minutes per region
# - MSK Replicator: 15-30 minutes (can take up to 30 min per AWS docs)
# - Total: ~2.5-3.5 hours

param(
    [string]$EnvironmentName = "production",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "us-west-2",
    [switch]$DeployMSKReplicator = $false,
    [switch]$SkipVPC = $false
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Wait-StackComplete {
    param(
        [string]$StackName,
        [string]$Region,
        [string]$Operation = "create",
        [int]$TimeoutMinutes = 60
    )
    
    $startTime = Get-Date
    Write-Host "Waiting for $StackName to complete ($Operation)..." -ForegroundColor Yellow
    
    try {
        if ($Operation -eq "create") {
            aws cloudformation wait stack-create-complete --stack-name $StackName --region $Region
        } else {
            aws cloudformation wait stack-update-complete --stack-name $StackName --region $Region
        }
    } catch {
        # Check if it's a timeout or actual failure
        $status = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].StackStatus" --output text
        if ($status -like "*IN_PROGRESS*") {
            Write-Host "  CloudFormation waiter timed out, but stack is still in progress. Continuing to wait..." -ForegroundColor Yellow
            # Continue waiting manually
            do {
                Start-Sleep -Seconds 30
                $status = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].StackStatus" --output text
                $elapsed = ((Get-Date) - $startTime).TotalMinutes
                Write-Host "  Stack Status: $status (elapsed: $([math]::Round($elapsed, 1)) min)"
            } while ($status -like "*IN_PROGRESS*" -and $elapsed -lt $TimeoutMinutes)
        }
    }
    
    $status = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].StackStatus" --output text
    $elapsed = ((Get-Date) - $startTime).TotalMinutes
    
    if ($status -like "*COMPLETE" -and $status -notlike "*ROLLBACK*") {
        Write-Host "$StackName completed successfully: $status (took $([math]::Round($elapsed, 1)) min)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "$StackName failed: $status" -ForegroundColor Red
        return $false
    }
}

function Wait-MSKActive {
    param(
        [string]$ClusterArn,
        [string]$Region,
        [int]$TimeoutMinutes = 30
    )
    
    $startTime = Get-Date
    Write-Host "Waiting for MSK cluster to become ACTIVE (typically 15-25 min for connectivity update)..." -ForegroundColor Yellow
    
    do {
        Start-Sleep -Seconds 30
        $state = aws kafka describe-cluster --cluster-arn $ClusterArn --query "ClusterInfo.State" --output text --region $Region
        $elapsed = ((Get-Date) - $startTime).TotalMinutes
        Write-Host "  MSK State: $state (elapsed: $([math]::Round($elapsed, 1)) min)"
    } while ($state -ne "ACTIVE" -and $elapsed -lt $TimeoutMinutes)
    
    if ($state -eq "ACTIVE") {
        Write-Host "MSK cluster is ACTIVE (took $([math]::Round($elapsed, 1)) min)" -ForegroundColor Green
        return $true
    } else {
        Write-Host "MSK cluster did not become ACTIVE within timeout" -ForegroundColor Red
        return $false
    }
}

function Test-StackExists {
    param(
        [string]$StackName,
        [string]$Region
    )
    
    try {
        $status = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].StackStatus" --output text 2>$null
        if ($status -and $status -notlike "*ROLLBACK*" -and $status -notlike "*FAILED*" -and $status -notlike "*DELETE*") {
            return $status
        }
    } catch {}
    return $null
}

Write-Host @"

╔══════════════════════════════════════════════════════════════════╗
║     Cross-Region Active-Active OpenSearch Deployment Script      ║
╠══════════════════════════════════════════════════════════════════╣
║  Environment: $EnvironmentName
║  Primary Region: $PrimaryRegion
║  Secondary Region: $SecondaryRegion
║  Deploy MSK Replicator: $DeployMSKReplicator
╚══════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

# ============================================
# STEP 1: Deploy VPCs (~10 min each)
# ============================================
if (-not $SkipVPC) {
    Write-Step "Step 1: Deploying VPC Infrastructure (~10 min per region)"
    
    $primaryVpcStatus = Test-StackExists -StackName "$EnvironmentName-vpc-primary" -Region $PrimaryRegion
    $secondaryVpcStatus = Test-StackExists -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion
    
    if (-not $primaryVpcStatus) {
        Write-Host "Deploying Primary VPC in $PrimaryRegion..." -ForegroundColor Yellow
        aws cloudformation create-stack `
            --stack-name "$EnvironmentName-vpc-primary" `
            --template-body file://cloudformation/vpc-infrastructure.yaml `
            --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
            --region $PrimaryRegion `
            --capabilities CAPABILITY_NAMED_IAM
    } else {
        Write-Host "Primary VPC already exists: $primaryVpcStatus" -ForegroundColor Green
    }
    
    if (-not $secondaryVpcStatus) {
        Write-Host "Deploying Secondary VPC in $SecondaryRegion..." -ForegroundColor Yellow
        aws cloudformation create-stack `
            --stack-name "$EnvironmentName-vpc-secondary" `
            --template-body file://cloudformation/vpc-infrastructure.yaml `
            --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName ParameterKey=VpcCIDR,ParameterValue=10.1.0.0/16 `
            --region $SecondaryRegion `
            --capabilities CAPABILITY_NAMED_IAM
    } else {
        Write-Host "Secondary VPC already exists: $secondaryVpcStatus" -ForegroundColor Green
    }
    
    # Wait for VPCs (parallel deployment, wait for both)
    if (-not $primaryVpcStatus) {
        Wait-StackComplete -StackName "$EnvironmentName-vpc-primary" -Region $PrimaryRegion -TimeoutMinutes 15
    }
    if (-not $secondaryVpcStatus) {
        Wait-StackComplete -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion -TimeoutMinutes 15
    }
} else {
    Write-Host "Skipping VPC deployment (--SkipVPC flag set)" -ForegroundColor Yellow
}

# ============================================
# STEP 2: Deploy Primary Region Phase 1 (~35 min)
# MSK Cluster + OpenSearch Collection (no OSI yet)
# ============================================
Write-Step "Step 2: Deploying Primary Region Phase 1 - MSK + OpenSearch (~35 min)"
Write-Info "MSK cluster creation takes 25-35 minutes"

$primaryStackStatus = Test-StackExists -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion

if (-not $primaryStackStatus) {
    aws cloudformation create-stack `
        --stack-name "$EnvironmentName-opensearch-primary" `
        --template-body file://cloudformation/primary-region.yaml `
        --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
                     ParameterKey=UseExistingVPC,ParameterValue=false `
                     ParameterKey=DeployOSIPipeline,ParameterValue=false `
        --region $PrimaryRegion `
        --capabilities CAPABILITY_NAMED_IAM
    
    Wait-StackComplete -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion -TimeoutMinutes 45
} else {
    Write-Host "Primary stack already exists: $primaryStackStatus" -ForegroundColor Green
}

# ============================================
# STEP 3: Enable Multi-VPC Connectivity (Primary) (~20 min)
# ============================================
Write-Step "Step 3: Enabling Multi-VPC Connectivity on Primary MSK (~15-25 min)"
Write-Info "This is required for OSI pipeline to connect to MSK"

$PRIMARY_MSK_ARN = aws cloudformation describe-stacks `
    --stack-name "$EnvironmentName-opensearch-primary" `
    --region $PrimaryRegion `
    --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" `
    --output text

# Check if multi-VPC is already enabled
$connectivityInfo = aws kafka describe-cluster --cluster-arn $PRIMARY_MSK_ARN --region $PrimaryRegion --query "ClusterInfo.BrokerNodeGroupInfo.ConnectivityInfo.VpcConnectivity" --output json 2>$null

if ($connectivityInfo -eq "null" -or -not $connectivityInfo) {
    $CURRENT_VERSION = aws kafka describe-cluster `
        --cluster-arn $PRIMARY_MSK_ARN `
        --query "ClusterInfo.CurrentVersion" `
        --output text `
        --region $PrimaryRegion
    
    Write-Host "Enabling multi-VPC connectivity..." -ForegroundColor Yellow
    aws kafka update-connectivity `
        --cluster-arn $PRIMARY_MSK_ARN `
        --current-version $CURRENT_VERSION `
        --connectivity-info '{"VpcConnectivity":{"ClientAuthentication":{"Sasl":{"Iam":{"Enabled":true}}}}}' `
        --region $PrimaryRegion
    
    Wait-MSKActive -ClusterArn $PRIMARY_MSK_ARN -Region $PrimaryRegion -TimeoutMinutes 30
} else {
    Write-Host "Multi-VPC connectivity already enabled on Primary MSK" -ForegroundColor Green
}

# ============================================
# STEP 4: Deploy Primary Region Phase 2 (~10 min)
# Add OSI Pipeline
# ============================================
Write-Step "Step 4: Deploying Primary Region Phase 2 - Add OSI Pipeline (~5-10 min)"

aws cloudformation update-stack `
    --stack-name "$EnvironmentName-opensearch-primary" `
    --template-body file://cloudformation/primary-region.yaml `
    --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
                 ParameterKey=UseExistingVPC,ParameterValue=false `
                 ParameterKey=DeployOSIPipeline,ParameterValue=true `
    --region $PrimaryRegion `
    --capabilities CAPABILITY_NAMED_IAM 2>$null

if ($LASTEXITCODE -eq 0) {
    Wait-StackComplete -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion -Operation "update" -TimeoutMinutes 20
} else {
    Write-Host "No updates needed for primary stack (OSI may already be deployed)" -ForegroundColor Yellow
}

# ============================================
# STEP 5: Deploy Secondary Region Phase 1 (~35 min)
# MSK Cluster + OpenSearch Collection (no OSI/Replicator yet)
# ============================================
Write-Step "Step 5: Deploying Secondary Region Phase 1 - MSK + OpenSearch (~35 min)"
Write-Info "MSK cluster creation takes 25-35 minutes"

$secondaryStackStatus = Test-StackExists -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion

if (-not $secondaryStackStatus) {
    aws cloudformation create-stack `
        --stack-name "$EnvironmentName-opensearch-secondary" `
        --template-body file://cloudformation/secondary-region.yaml `
        --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
                     ParameterKey=UseExistingVPC,ParameterValue=false `
                     ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
                     ParameterKey=DeployOSIPipeline,ParameterValue=false `
                     ParameterKey=DeployMSKReplicator,ParameterValue=false `
        --region $SecondaryRegion `
        --capabilities CAPABILITY_NAMED_IAM
    
    Wait-StackComplete -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion -TimeoutMinutes 45
} else {
    Write-Host "Secondary stack already exists: $secondaryStackStatus" -ForegroundColor Green
}

# ============================================
# STEP 6: Enable Multi-VPC Connectivity (Secondary) (~20 min)
# ============================================
Write-Step "Step 6: Enabling Multi-VPC Connectivity on Secondary MSK (~15-25 min)"

$SECONDARY_MSK_ARN = aws cloudformation describe-stacks `
    --stack-name "$EnvironmentName-opensearch-secondary" `
    --region $SecondaryRegion `
    --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" `
    --output text

# Check if multi-VPC is already enabled
$connectivityInfo = aws kafka describe-cluster --cluster-arn $SECONDARY_MSK_ARN --region $SecondaryRegion --query "ClusterInfo.BrokerNodeGroupInfo.ConnectivityInfo.VpcConnectivity" --output json 2>$null

if ($connectivityInfo -eq "null" -or -not $connectivityInfo) {
    $CURRENT_VERSION = aws kafka describe-cluster `
        --cluster-arn $SECONDARY_MSK_ARN `
        --query "ClusterInfo.CurrentVersion" `
        --output text `
        --region $SecondaryRegion
    
    Write-Host "Enabling multi-VPC connectivity..." -ForegroundColor Yellow
    aws kafka update-connectivity `
        --cluster-arn $SECONDARY_MSK_ARN `
        --current-version $CURRENT_VERSION `
        --connectivity-info '{"VpcConnectivity":{"ClientAuthentication":{"Sasl":{"Iam":{"Enabled":true}}}}}' `
        --region $SecondaryRegion
    
    Wait-MSKActive -ClusterArn $SECONDARY_MSK_ARN -Region $SecondaryRegion -TimeoutMinutes 30
} else {
    Write-Host "Multi-VPC connectivity already enabled on Secondary MSK" -ForegroundColor Green
}

# ============================================
# STEP 7: Deploy Secondary Region Phase 2 (~10 min)
# Add OSI Pipeline
# ============================================
Write-Step "Step 7: Deploying Secondary Region Phase 2 - Add OSI Pipeline (~5-10 min)"

aws cloudformation update-stack `
    --stack-name "$EnvironmentName-opensearch-secondary" `
    --template-body file://cloudformation/secondary-region.yaml `
    --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
                 ParameterKey=UseExistingVPC,ParameterValue=false `
                 ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
                 ParameterKey=DeployOSIPipeline,ParameterValue=true `
                 ParameterKey=DeployMSKReplicator,ParameterValue=false `
    --region $SecondaryRegion `
    --capabilities CAPABILITY_NAMED_IAM 2>$null

if ($LASTEXITCODE -eq 0) {
    Wait-StackComplete -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion -Operation "update" -TimeoutMinutes 20
} else {
    Write-Host "No updates needed for secondary stack (OSI may already be deployed)" -ForegroundColor Yellow
}

# ============================================
# STEP 8: Deploy MSK Replicator (Optional) (~15 min)
# NOTE: MSK Replicator often times out in CloudFormation. If it fails,
# the script will attempt to create it via CLI instead.
# ============================================
if ($DeployMSKReplicator) {
    Write-Step "Step 8: Deploying MSK Replicator (~15-30 min)"
    Write-Info "MSK Replicator enables cross-region data synchronization"
    Write-Info "MSK Replicator can take up to 30 minutes to create (per AWS docs)"
    Write-Info "For cross-region replication, each cluster needs VPC config from its own region"
    
    # Get primary region VPC info for MSK Replicator
    $PRIMARY_SUBNETS = @(
        (aws cloudformation describe-stacks --stack-name "$EnvironmentName-vpc-primary" --region $PrimaryRegion --query "Stacks[0].Outputs[?OutputKey==``PrivateSubnet1``].OutputValue" --output text),
        (aws cloudformation describe-stacks --stack-name "$EnvironmentName-vpc-primary" --region $PrimaryRegion --query "Stacks[0].Outputs[?OutputKey==``PrivateSubnet2``].OutputValue" --output text),
        (aws cloudformation describe-stacks --stack-name "$EnvironmentName-vpc-primary" --region $PrimaryRegion --query "Stacks[0].Outputs[?OutputKey==``PrivateSubnet3``].OutputValue" --output text)
    ) -join ","
    
    $PRIMARY_SG = aws cloudformation describe-stacks --stack-name "$EnvironmentName-opensearch-primary" --region $PrimaryRegion --query "Stacks[0].Outputs[?OutputKey==``MSKSecurityGroupId``].OutputValue" --output text
    
    Write-Info "Primary subnets: $PRIMARY_SUBNETS"
    Write-Info "Primary security group: $PRIMARY_SG"
    
    # Try CloudFormation first
    $cfnResult = aws cloudformation update-stack `
        --stack-name "$EnvironmentName-opensearch-secondary" `
        --template-body file://cloudformation/secondary-region.yaml `
        --parameters ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
                     ParameterKey=UseExistingVPC,ParameterValue=false `
                     ParameterKey=PrimaryMSKClusterArn,ParameterValue=$PRIMARY_MSK_ARN `
                     ParameterKey=PrimaryPrivateSubnetIds,ParameterValue="$PRIMARY_SUBNETS" `
                     ParameterKey=PrimaryMSKSecurityGroupId,ParameterValue=$PRIMARY_SG `
                     ParameterKey=DeployOSIPipeline,ParameterValue=true `
                     ParameterKey=DeployMSKReplicator,ParameterValue=true `
        --region $SecondaryRegion `
        --capabilities CAPABILITY_NAMED_IAM 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $stackComplete = Wait-StackComplete -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion -Operation "update" -TimeoutMinutes 30
        
        if (-not $stackComplete) {
            Write-Host "CloudFormation timed out. Checking if replicator was created..." -ForegroundColor Yellow
            $replicatorState = aws kafka list-replicators --region $SecondaryRegion --query "Replicators[?ReplicatorName=='$EnvironmentName-msk-replicator'].ReplicatorState" --output text
            if ($replicatorState -eq "RUNNING") {
                Write-Host "MSK Replicator is RUNNING despite CloudFormation timeout" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "CloudFormation update failed or no changes. Checking existing replicator..." -ForegroundColor Yellow
        $replicatorState = aws kafka list-replicators --region $SecondaryRegion --query "Replicators[?ReplicatorName=='$EnvironmentName-msk-replicator'].ReplicatorState" --output text
        if ($replicatorState) {
            Write-Host "MSK Replicator exists with state: $replicatorState" -ForegroundColor Green
        } else {
            Write-Host "No replicator found. You may need to create it via CLI." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`nSkipping MSK Replicator deployment. To deploy later, run:" -ForegroundColor Yellow
    Write-Host "  .\scripts\deploy-all.ps1 -DeployMSKReplicator" -ForegroundColor Gray
}

# ============================================
# SUMMARY
# ============================================
Write-Step "Deployment Complete!"

Write-Host "`n=== Primary Region ($PrimaryRegion) ===" -ForegroundColor Green
Write-Host "MSK Clusters:" -ForegroundColor Yellow
aws kafka list-clusters --region $PrimaryRegion --query "ClusterInfoList[].{Name:ClusterName,State:State}" --output table
Write-Host "OpenSearch Collections:" -ForegroundColor Yellow
aws opensearchserverless list-collections --region $PrimaryRegion --query "collectionSummaries[?contains(name,'$EnvironmentName')].{Name:name,Status:status}" --output table
Write-Host "OSI Pipelines:" -ForegroundColor Yellow
aws osis list-pipelines --region $PrimaryRegion --query "Pipelines[?contains(PipelineName,'$EnvironmentName')].{Name:PipelineName,Status:Status}" --output table

Write-Host "`n=== Secondary Region ($SecondaryRegion) ===" -ForegroundColor Green
Write-Host "MSK Clusters:" -ForegroundColor Yellow
aws kafka list-clusters --region $SecondaryRegion --query "ClusterInfoList[].{Name:ClusterName,State:State}" --output table
Write-Host "OpenSearch Collections:" -ForegroundColor Yellow
aws opensearchserverless list-collections --region $SecondaryRegion --query "collectionSummaries[?contains(name,'$EnvironmentName')].{Name:name,Status:status}" --output table
Write-Host "OSI Pipelines:" -ForegroundColor Yellow
aws osis list-pipelines --region $SecondaryRegion --query "Pipelines[?contains(PipelineName,'$EnvironmentName')].{Name:PipelineName,Status:Status}" --output table

Write-Host "`n=== MSK Replicator ===" -ForegroundColor Green
aws kafka list-replicators --region $SecondaryRegion --query "Replicators[?contains(ReplicatorName,'$EnvironmentName')].{Name:ReplicatorName,State:ReplicatorState}" --output table

Write-Host @"

╔══════════════════════════════════════════════════════════════════╗
║                    NEXT STEPS                                    ║
╠══════════════════════════════════════════════════════════════════╣
║  1. Test data flow by sending messages to MSK                    ║
║  2. Verify data appears in OpenSearch collections                ║
║  3. If MSK Replicator not deployed, run with -DeployMSKReplicator║
╚══════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan
