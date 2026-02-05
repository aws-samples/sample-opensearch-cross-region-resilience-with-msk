# test-active-active.ps1
# Test script for Active-Active MSK Replication with OpenSearch

param(
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "us-west-2",
    [string]$Environment = "production",
    [int]$MessageCount = 10
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Active-Active Replication Test" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Verify all components are running
Write-Host "Step 1: Verifying Infrastructure Status" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow

Write-Host "`nMSK Clusters:" -ForegroundColor White
aws kafka list-clusters --region $PrimaryRegion --query "ClusterInfoList[?contains(ClusterName,'$Environment')].{Name:ClusterName,State:State}" --output table
aws kafka list-clusters --region $SecondaryRegion --query "ClusterInfoList[?contains(ClusterName,'$Environment')].{Name:ClusterName,State:State}" --output table

Write-Host "`nMSK Replicators (Bidirectional):" -ForegroundColor White
aws kafka list-replicators --region $PrimaryRegion --query "Replicators[].{Name:ReplicatorName,State:ReplicatorState,Direction:'See ReplicationInfo'}" --output table

Write-Host "`nOpenSearch Collections:" -ForegroundColor White
aws opensearchserverless list-collections --region $PrimaryRegion --query "collectionSummaries[?contains(name,'$Environment')].{Name:name,Status:status}" --output table
aws opensearchserverless list-collections --region $SecondaryRegion --query "collectionSummaries[?contains(name,'$Environment')].{Name:name,Status:status}" --output table

Write-Host "`nOSI Pipelines:" -ForegroundColor White
aws osis list-pipelines --region $PrimaryRegion --query "Pipelines[?contains(PipelineName,'$Environment')].{Name:PipelineName,Status:Status}" --output table
aws osis list-pipelines --region $SecondaryRegion --query "Pipelines[?contains(PipelineName,'$Environment')].{Name:PipelineName,Status:Status}" --output table

# Step 2: Check MSK Replicator metrics
Write-Host "`nStep 2: MSK Replicator Metrics" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow

$replicators = aws kafka list-replicators --region $PrimaryRegion --query "Replicators[].ReplicatorName" --output json | ConvertFrom-Json

foreach ($replicator in $replicators) {
    Write-Host "`nReplicator: $replicator" -ForegroundColor Cyan
    
    # Get replication lag metric
    $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $startTime = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $metrics = aws cloudwatch get-metric-statistics `
        --namespace "AWS/KafkaReplicator" `
        --metric-name "ReplicationLatency" `
        --dimensions "Name=ReplicatorName,Value=$replicator" `
        --start-time $startTime `
        --end-time $endTime `
        --period 300 `
        --statistics Average `
        --region $PrimaryRegion `
        --output json 2>$null | ConvertFrom-Json
    
    if ($metrics.Datapoints.Count -gt 0) {
        $latestLag = ($metrics.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Average
        Write-Host "  Replication Latency: $([math]::Round($latestLag, 2)) ms" -ForegroundColor Green
    } else {
        Write-Host "  Replication Latency: No data yet (normal for new replicators)" -ForegroundColor Yellow
    }
}

# Step 3: Display connection info for manual testing
Write-Host "`nStep 3: Connection Information for Manual Testing" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow

$primaryMskArn = aws kafka list-clusters --region $PrimaryRegion --query "ClusterInfoList[?contains(ClusterName,'$Environment-msk-primary')].ClusterArn" --output text
$secondaryMskArn = aws kafka list-clusters --region $SecondaryRegion --query "ClusterInfoList[?contains(ClusterName,'$Environment-msk-secondary')].ClusterArn" --output text

Write-Host "`nPrimary MSK Bootstrap Servers (us-east-1):" -ForegroundColor White
aws kafka get-bootstrap-brokers --cluster-arn $primaryMskArn --region $PrimaryRegion --query "BootstrapBrokerStringSaslIam" --output text

Write-Host "`nSecondary MSK Bootstrap Servers (us-west-2):" -ForegroundColor White
aws kafka get-bootstrap-brokers --cluster-arn $secondaryMskArn --region $SecondaryRegion --query "BootstrapBrokerStringSaslIam" --output text

Write-Host "`nOpenSearch Endpoints:" -ForegroundColor White
$primaryCollection = aws opensearchserverless list-collections --region $PrimaryRegion --query "collectionSummaries[?contains(name,'$Environment-opensearch-primary')].id" --output text
$secondaryCollection = aws opensearchserverless list-collections --region $SecondaryRegion --query "collectionSummaries[?contains(name,'$Environment-opensearch-secondary')].id" --output text

if ($primaryCollection) {
    $primaryEndpoint = aws opensearchserverless batch-get-collection --ids $primaryCollection --region $PrimaryRegion --query "collectionDetails[0].collectionEndpoint" --output text
    Write-Host "  Primary: $primaryEndpoint" -ForegroundColor Green
}
if ($secondaryCollection) {
    $secondaryEndpoint = aws opensearchserverless batch-get-collection --ids $secondaryCollection --region $SecondaryRegion --query "collectionDetails[0].collectionEndpoint" --output text
    Write-Host "  Secondary: $secondaryEndpoint" -ForegroundColor Green
}

# Step 4: Test instructions
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  Testing Instructions" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Write-Host @"

To fully test the active-active setup, you need to:

1. PRODUCE DATA TO PRIMARY REGION:
   From an EC2 instance in the primary VPC, run:
   
   python scripts/test-producer.py \
     --bootstrap-servers <PRIMARY_BOOTSTRAP_SERVERS> \
     --region us-east-1 \
     --count 100

2. PRODUCE DATA TO SECONDARY REGION:
   From an EC2 instance in the secondary VPC, run:
   
   python scripts/test-producer.py \
     --bootstrap-servers <SECONDARY_BOOTSTRAP_SERVERS> \
     --region us-west-2 \
     --count 100

3. VERIFY REPLICATION:
   - Data produced to PRIMARY should appear in SECONDARY OpenSearch
   - Data produced to SECONDARY should appear in PRIMARY OpenSearch
   - Both OpenSearch collections should have data from both regions

4. CHECK OPENSEARCH DASHBOARDS:
   - Primary: $primaryEndpoint/_dashboards
   - Secondary: $secondaryEndpoint/_dashboards
   
   Query: GET application-logs-*/_search

5. MONITOR REPLICATION:
   - CloudWatch Metrics: AWS/KafkaReplicator namespace
   - Key metrics: ReplicationLatency, MessageLag, BytesReplicated

"@ -ForegroundColor White

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Test Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
