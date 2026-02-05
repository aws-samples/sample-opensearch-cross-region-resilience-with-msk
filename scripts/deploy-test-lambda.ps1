# deploy-test-lambda.ps1
# Deploy Lambda function for testing MSK Active-Active replication

param(
    [string]$Region = "us-east-1",
    [string]$Environment = "production"
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Deploying MSK Test Lambda" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Get VPC info dynamically
Write-Host "`nGetting VPC configuration..." -ForegroundColor Yellow

$VpcId = aws ec2 describe-vpcs --region $Region --filters "Name=tag:Name,Values=*$Environment*" --query "Vpcs[0].VpcId" --output text
$Subnets = aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$VpcId" "Name=tag:Name,Values=*private*" --query "Subnets[*].SubnetId" --output text

# Get MSK ARN from CloudFormation stack
if ($Region -eq "us-east-1") {
    $StackName = "$Environment-opensearch-primary"
} else {
    $StackName = "$Environment-opensearch-secondary"
}

$MSKArn = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[?OutputKey=='MSKClusterArn'].OutputValue" --output text
$SGId = aws cloudformation describe-stacks --stack-name $StackName --region $Region --query "Stacks[0].Outputs[?OutputKey=='MSKSecurityGroupId'].OutputValue" --output text

Write-Host "VPC: $VpcId"
Write-Host "Subnets: $Subnets"
Write-Host "MSK ARN: $MSKArn"
Write-Host "Security Group: $SGId"

# Validate we got the values
if (-not $MSKArn -or $MSKArn -eq "None") {
    Write-Host "ERROR: Could not retrieve MSK ARN from CloudFormation stack $StackName" -ForegroundColor Red
    Write-Host "Make sure the stack is deployed and has the MSKClusterArn output" -ForegroundColor Yellow
    exit 1
}

Write-Host "`nConfiguration retrieved successfully!" -ForegroundColor Green
