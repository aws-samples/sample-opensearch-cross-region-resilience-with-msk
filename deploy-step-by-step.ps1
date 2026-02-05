# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# DISCLAIMER: This code is provided as a reference implementation and is not
# intended for production use without thorough review and customization.
#
# deploy-step-by-step.ps1
# Step-by-step deployment script with status checks

param(
    [string]$EnvironmentName = "production",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "us-west-2"
)

# Color functions
function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Blue }
function Write-Success { param([string]$Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Error { param([string]$Message) Write-Host "✗ $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "ℹ $Message" -ForegroundColor Cyan }

# Function to check stack status
function Get-StackStatus {
    param([string]$StackName, [string]$Region)
    $status = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query 'Stacks[0].StackStatus' --output text 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $status
    } else {
        return "NOT_FOUND"
    }
}

# Function to wait for stack
function Wait-ForStack {
    param([string]$StackName, [string]$Region, [string]$DesiredStatus = "CREATE_COMPLETE")
    
    Write-Info "Waiting for $StackName to reach $DesiredStatus..."
    $timeout = 3600 # 60 minutes
    $elapsed = 0
    $interval = 30
    
    while ($elapsed -lt $timeout) {
        $status = Get-StackStatus -StackName $StackName -Region $Region
        
        if ($status -eq $DesiredStatus) {
            Write-Success "$StackName is $DesiredStatus"
            return $true
        } elseif ($status -like "*FAILED*" -or $status -like "*ROLLBACK*") {
            Write-Error "$StackName failed with status: $status"
            return $false
        } elseif ($status -eq "NOT_FOUND" -and $DesiredStatus -eq "DELETE_COMPLETE") {
            Write-Success "$StackName deleted"
            return $true
        }
        
        Write-Host "  Status: $status (${elapsed}s elapsed)" -ForegroundColor Yellow
        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
    
    Write-Error "Timeout waiting for $StackName"
    return $false
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenSearch Deployment - Step by Step" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Check current status
Write-Step "Step 1: Checking Current Status"

$primaryVpcStatus = Get-StackStatus -StackName "$EnvironmentName-vpc-primary" -Region $PrimaryRegion
$secondaryVpcStatus = Get-StackStatus -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion
$primaryAppStatus = Get-StackStatus -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion
$secondaryAppStatus = Get-StackStatus -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion

Write-Host "Primary VPC:          $primaryVpcStatus"
Write-Host "Secondary VPC:        $secondaryVpcStatus"
Write-Host "Primary Application:  $primaryAppStatus"
Write-Host "Secondary Application: $secondaryAppStatus"

# Step 2: Handle Secondary VPC
if ($secondaryVpcStatus -eq "ROLLBACK_COMPLETE") {
    Write-Step "Step 2: Fixing Secondary VPC"
    Write-Info "Deleting failed secondary VPC..."
    aws cloudformation delete-stack --stack-name "$EnvironmentName-vpc-secondary" --region $SecondaryRegion
    Wait-ForStack -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion -DesiredStatus "DELETE_COMPLETE"
    $secondaryVpcStatus = "NOT_FOUND"
}

if ($secondaryVpcStatus -eq "NOT_FOUND") {
    Write-Step "Step 2: Creating Secondary VPC"
    Write-Info "Creating secondary VPC in $SecondaryRegion..."
    
    $stackId = aws cloudformation create-stack `
        --stack-name "$EnvironmentName-vpc-secondary" `
        --template-body file://cloudformation/vpc-infrastructure.yaml `
        --parameters `
            ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
            ParameterKey=VpcCIDR,ParameterValue=10.1.0.0/16 `
            ParameterKey=PrivateSubnet1CIDR,ParameterValue=10.1.1.0/24 `
            ParameterKey=PrivateSubnet2CIDR,ParameterValue=10.1.2.0/24 `
            ParameterKey=PrivateSubnet3CIDR,ParameterValue=10.1.3.0/24 `
        --region $SecondaryRegion `
        --capabilities CAPABILITY_NAMED_IAM 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Secondary VPC creation initiated"
        Wait-ForStack -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion
    } else {
        Write-Error "Failed to create secondary VPC: $stackId"
        exit 1
    }
}

# Step 3: Deploy Primary Application
if ($primaryAppStatus -eq "NOT_FOUND" -and $primaryVpcStatus -eq "CREATE_COMPLETE") {
    Write-Step "Step 3: Deploying Primary Application"
    Write-Info "This will take 30-45 minutes..."
    
    $stackId = aws cloudformation create-stack `
        --stack-name "$EnvironmentName-opensearch-primary" `
        --template-body file://cloudformation/primary-region.yaml `
        --parameters `
            ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
            ParameterKey=UseExistingVPC,ParameterValue=false `
        --region $PrimaryRegion `
        --capabilities CAPABILITY_NAMED_IAM 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Primary application creation initiated"
        Wait-ForStack -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion
    } else {
        Write-Error "Failed to create primary application: $stackId"
        exit 1
    }
}

# Step 4: Get Primary MSK ARN
if ($primaryAppStatus -eq "CREATE_COMPLETE" -or (Get-StackStatus -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion) -eq "CREATE_COMPLETE") {
    Write-Step "Step 4: Getting Primary MSK ARN"
    $primaryMskArn = aws cloudformation describe-stacks `
        --stack-name "$EnvironmentName-opensearch-primary" `
        --region $PrimaryRegion `
        --query 'Stacks[0].Outputs[?OutputKey==`MSKClusterArn`].OutputValue' `
        --output text
    
    Write-Success "Primary MSK ARN: $primaryMskArn"
    $env:PRIMARY_MSK_ARN = $primaryMskArn
}

# Step 5: Deploy Secondary Application
if ($secondaryAppStatus -eq "NOT_FOUND" -and $secondaryVpcStatus -eq "CREATE_COMPLETE" -and $env:PRIMARY_MSK_ARN) {
    Write-Step "Step 5: Deploying Secondary Application"
    Write-Info "This will take 30-45 minutes..."
    
    $stackId = aws cloudformation create-stack `
        --stack-name "$EnvironmentName-opensearch-secondary" `
        --template-body file://cloudformation/secondary-region.yaml `
        --parameters `
            ParameterKey=EnvironmentName,ParameterValue=$EnvironmentName `
            ParameterKey=UseExistingVPC,ParameterValue=false `
            ParameterKey=PrimaryMSKClusterArn,ParameterValue=$env:PRIMARY_MSK_ARN `
        --region $SecondaryRegion `
        --capabilities CAPABILITY_NAMED_IAM 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Secondary application creation initiated"
        Wait-ForStack -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion
    } else {
        Write-Error "Failed to create secondary application: $stackId"
        exit 1
    }
}

# Final Status
Write-Step "Deployment Complete!"
Write-Host "`nFinal Status:" -ForegroundColor Cyan
Write-Host "Primary VPC:          $(Get-StackStatus -StackName "$EnvironmentName-vpc-primary" -Region $PrimaryRegion)"
Write-Host "Secondary VPC:        $(Get-StackStatus -StackName "$EnvironmentName-vpc-secondary" -Region $SecondaryRegion)"
Write-Host "Primary Application:  $(Get-StackStatus -StackName "$EnvironmentName-opensearch-primary" -Region $PrimaryRegion)"
Write-Host "Secondary Application: $(Get-StackStatus -StackName "$EnvironmentName-opensearch-secondary" -Region $SecondaryRegion)"

Write-Host ""
Write-Host "Run validation script to test:" -ForegroundColor Green
Write-Host "  .\scripts\validate-replication.ps1" -ForegroundColor Cyan
