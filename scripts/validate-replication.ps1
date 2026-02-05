# validate-replication.ps1
# PowerShell script to validate cross-region replication for OpenSearch MSK solution

param(
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "us-west-2",
    [string]$Environment = "production"
)

# Color output functions
function Write-Success { param([string]$Message) Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Error { param([string]$Message) Write-Host "✗ $Message" -ForegroundColor Red }
function Write-Warning { param([string]$Message) Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "ℹ $Message" -ForegroundColor Cyan }

Write-Host "========================================" -ForegroundColor Blue
Write-Host "  Cross-Region Replication Validator" -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Blue
Write-Host ""

# Check AWS CLI
Write-Info "Checking AWS CLI installation..."
try {
    $awsVersion = aws --version 2>&1
    Write-Success "AWS CLI is installed: $awsVersion"
} catch {
    Write-Error "AWS CLI is not installed"
    exit 1
}

# Verify AWS credentials
Write-Info "Verifying AWS credentials..."
try {
    $identity = aws sts get-caller-identity --output json | ConvertFrom-Json
    Write-Success "AWS credentials configured for account: $($identity.Account)"
} catch {
    Write-Error "AWS credentials not configured properly"
    exit 1
}

Write-Host ""

# Function to validate MSK cluster
function Test-MSKCluster {
    param([string]$Region, [string]$ClusterName)
    
    Write-Info "Validating MSK cluster in $Region..."
    
    try {
        $clusterArn = aws kafka list-clusters-v2 `
            --region $Region `
            --query "ClusterInfoList[?ClusterName=='$Environment-msk-$ClusterName'].ClusterArn" `
            --output text 2>$null
        
        if ([string]::IsNullOrEmpty($clusterArn)) {
            Write-Error "MSK cluster not found in $Region"
            return $false
        }
        
        $state = aws kafka describe-cluster-v2 `
            --region $Region `
            --cluster-arn $clusterArn `
            --query 'ClusterInfo.State' `
            --output text
        
        if ($state -eq "ACTIVE") {
            Write-Success "MSK cluster is ACTIVE in $Region"
            return $true
        } else {
            Write-Warning "MSK cluster state: $state in $Region"
            return $false
        }
    } catch {
        Write-Error "Error checking MSK cluster: $_"
        return $false
    }
}

# Function to validate OpenSearch collection
function Test-OpenSearchCollection {
    param([string]$Region, [string]$CollectionName)
    
    Write-Info "Validating OpenSearch collection in $Region..."
    
    try {
        $collectionId = aws opensearchserverless list-collections `
            --region $Region `
            --query "collectionSummaries[?name=='$Environment-opensearch-$CollectionName'].id" `
            --output text 2>$null
        
        if ([string]::IsNullOrEmpty($collectionId)) {
            Write-Error "OpenSearch collection not found in $Region"
            return $false
        }
        
        $status = aws opensearchserverless batch-get-collection `
            --region $Region `
            --ids $collectionId `
            --query 'collectionDetails[0].status' `
            --output text
        
        if ($status -eq "ACTIVE") {
            Write-Success "OpenSearch collection is ACTIVE in $Region"
            return $true
        } else {
            Write-Warning "OpenSearch collection status: $status in $Region"
            return $false
        }
    } catch {
        Write-Error "Error checking OpenSearch collection: $_"
        return $false
    }
}

# Function to validate OSI pipeline
function Test-OSIPipeline {
    param([string]$Region, [string]$PipelineName)
    
    Write-Info "Validating OSI pipeline in $Region..."
    
    try {
        $pipelineStatus = aws osis list-pipelines `
            --region $Region `
            --query "Pipelines[?PipelineName=='$Environment-osi-$PipelineName'].Status" `
            --output text 2>$null
        
        if ([string]::IsNullOrEmpty($pipelineStatus)) {
            Write-Error "OSI pipeline not found in $Region"
            return $false
        }
        
        if ($pipelineStatus -eq "ACTIVE") {
            Write-Success "OSI pipeline is ACTIVE in $Region"
            return $true
        } else {
            Write-Warning "OSI pipeline status: $pipelineStatus in $Region"
            return $false
        }
    } catch {
        Write-Error "Error checking OSI pipeline: $_"
        return $false
    }
}

# Function to check MSK replication lag
function Test-ReplicationLag {
    Write-Info "Checking MSK replication lag..."
    
    try {
        $endTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
        $startTime = (Get-Date).AddMinutes(-5).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss")
        
        $lag = aws cloudwatch get-metric-statistics `
            --region $PrimaryRegion `
            --namespace AWS/Kafka `
            --metric-name ReplicationLatency `
            --dimensions Name=Source,Value=$PrimaryRegion Name=Target,Value=$SecondaryRegion `
            --start-time $startTime `
            --end-time $endTime `
            --period 300 `
            --statistics Average `
            --query 'Datapoints[-1].Average' `
            --output text 2>$null
        
        if ([string]::IsNullOrEmpty($lag) -or $lag -eq "None") {
            Write-Warning "No replication lag data available (this is normal for new deployments)"
        } else {
            $lagSeconds = [math]::Floor($lag / 1000)
            if ($lagSeconds -lt 60) {
                Write-Success "Replication lag: ${lagSeconds}s (healthy)"
            } else {
                Write-Warning "Replication lag: ${lagSeconds}s (consider investigating)"
            }
        }
    } catch {
        Write-Warning "Could not retrieve replication lag: $_"
    }
}

# Function to validate MSK replicator
function Test-MSKReplicator {
    Write-Info "Validating MSK Replicator..."
    
    try {
        $replicatorStatus = aws kafka list-replicators `
            --region $SecondaryRegion `
            --query "Replicators[?ReplicatorName=='$Environment-msk-replicator'].State" `
            --output text 2>$null
        
        if ([string]::IsNullOrEmpty($replicatorStatus)) {
            Write-Error "MSK Replicator not found"
            return $false
        }
        
        if ($replicatorStatus -eq "RUNNING") {
            Write-Success "MSK Replicator is RUNNING"
            return $true
        } else {
            Write-Warning "MSK Replicator status: $replicatorStatus"
            return $false
        }
    } catch {
        Write-Error "Error checking MSK Replicator: $_"
        return $false
    }
}

# Function to check CloudWatch alarms
function Test-Alarms {
    param([string]$Region, [string]$AlarmPrefix)
    
    Write-Info "Checking CloudWatch alarms in $Region..."
    
    try {
        $alarmCount = aws cloudwatch describe-alarms `
            --region $Region `
            --alarm-name-prefix $AlarmPrefix `
            --state-value ALARM `
            --query 'length(MetricAlarms)' `
            --output text 2>$null
        
        if ($alarmCount -eq 0) {
            Write-Success "No alarms in ALARM state in $Region"
        } else {
            Write-Warning "$alarmCount alarm(s) in ALARM state in $Region"
            aws cloudwatch describe-alarms `
                --region $Region `
                --alarm-name-prefix $AlarmPrefix `
                --state-value ALARM `
                --query 'MetricAlarms[*].[AlarmName,StateReason]' `
                --output table
        }
    } catch {
        Write-Warning "Could not check alarms: $_"
    }
}

# Main validation flow
Write-Host ""
Write-Info "Starting validation..."
Write-Host ""

# Validate Primary Region
Write-Host "=== Primary Region ($PrimaryRegion) ===" -ForegroundColor Blue
Test-MSKCluster -Region $PrimaryRegion -ClusterName "primary"
Test-OpenSearchCollection -Region $PrimaryRegion -CollectionName "primary"
Test-OSIPipeline -Region $PrimaryRegion -PipelineName "primary"
Test-Alarms -Region $PrimaryRegion -AlarmPrefix $Environment
Write-Host ""

# Validate Secondary Region
Write-Host "=== Secondary Region ($SecondaryRegion) ===" -ForegroundColor Blue
Test-MSKCluster -Region $SecondaryRegion -ClusterName "secondary"
Test-OpenSearchCollection -Region $SecondaryRegion -CollectionName "secondary"
Test-OSIPipeline -Region $SecondaryRegion -PipelineName "secondary"
Test-MSKReplicator
Test-Alarms -Region $SecondaryRegion -AlarmPrefix $Environment
Write-Host ""

# Check replication
Write-Host "=== Replication Status ===" -ForegroundColor Blue
Test-ReplicationLag
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Blue
Write-Host "✓ Validation Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Blue
Write-Host ""

Write-Info "Next Steps:"
Write-Host "  1. Produce test data: python scripts/test-producer.py --bootstrap-servers <MSK_ENDPOINT> --count 1000"
Write-Host "  2. Verify data in both regions using OpenSearch Dashboards"
Write-Host "  3. Monitor CloudWatch metrics for replication lag"
Write-Host "  4. Test failover by stopping primary region resources"
Write-Host ""
