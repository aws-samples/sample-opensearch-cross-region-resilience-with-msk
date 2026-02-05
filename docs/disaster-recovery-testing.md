# Disaster Recovery Testing Guide

This guide provides detailed instructions for testing failover and failback scenarios to validate the cross-region resilience of your OpenSearch deployment.

## Table of Contents

1. [Overview](#overview)
2. [Pre-Test Preparation](#pre-test-preparation)
3. [Scenario 1: Primary Region Failure](#scenario-1-primary-region-failure)
4. [Scenario 2: Secondary Region Failure](#scenario-2-secondary-region-failure)
5. [Scenario 3: Network Partition](#scenario-3-network-partition)
6. [Failback Procedures](#failback-procedures)
7. [Validation Checklist](#validation-checklist)
8. [Rollback Procedures](#rollback-procedures)

## Overview

Disaster recovery testing validates that your system can:
- Detect failures automatically
- Continue operations during Regional impairment
- Recover without data loss
- Resume normal operations without manual intervention

### Testing Philosophy

- **Non-Destructive**: Tests should not permanently damage infrastructure
- **Documented**: All steps should be recorded for audit purposes
- **Repeatable**: Tests should be automatable and repeatable
- **Validated**: Each test should have clear success criteria

## Pre-Test Preparation

### 1. Baseline Metrics

Before testing, capture baseline metrics:

```bash
#!/bin/bash
# Save baseline metrics

ENVIRONMENT="production"
PRIMARY_REGION="us-east-1"
SECONDARY_REGION="us-west-2"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "Capturing baseline metrics at ${TIMESTAMP}..."

# Document count in primary region
aws opensearchserverless batch-get-collection \
  --region ${PRIMARY_REGION} \
  --ids $(aws opensearchserverless list-collections \
    --region ${PRIMARY_REGION} \
    --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-primary'].id" \
    --output text) \
  > baseline_primary_${TIMESTAMP}.json

# Document count in secondary region
aws opensearchserverless batch-get-collection \
  --region ${SECONDARY_REGION} \
  --ids $(aws opensearchserverless list-collections \
    --region ${SECONDARY_REGION} \
    --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-secondary'].id" \
    --output text) \
  > baseline_secondary_${TIMESTAMP}.json

# MSK replication lag
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kafka \
  --metric-name ReplicationLatency \
  --dimensions Name=Source,Value=${PRIMARY_REGION} Name=Target,Value=${SECONDARY_REGION} \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average,Maximum \
  --region ${PRIMARY_REGION} \
  > baseline_replication_lag_${TIMESTAMP}.json

echo "✓ Baseline metrics saved"
```

### 2. Notification Setup

Set up notifications for the test:

```bash
# Create SNS topic for test notifications
aws sns create-topic \
  --name ${ENVIRONMENT}-dr-test-notifications \
  --region ${PRIMARY_REGION}

# Subscribe your email
aws sns subscribe \
  --topic-arn arn:aws:sns:${PRIMARY_REGION}:${AWS_ACCOUNT_ID}:${ENVIRONMENT}-dr-test-notifications \
  --protocol email \
  --notification-endpoint your-email@example.com
```

### 3. Test Data Generation

Generate test data to validate during failover:

```bash
# Generate unique test data batch
python scripts/test-producer.py \
  --bootstrap-servers ${PRIMARY_MSK_BOOTSTRAP} \
  --topic opensearch-data \
  --count 5000 \
  --region ${PRIMARY_REGION}

# Wait for data to replicate and be indexed
echo "Waiting for data propagation (3 minutes)..."
sleep 180

# Record test data identifiers
TEST_START_ID=$(date +%s)
echo "Test data start ID: ${TEST_START_ID}"
```

## Scenario 1: Primary Region Failure

This scenario simulates a complete failure of the primary region infrastructure.

### Step 1: Simulate Primary Region Failure

#### Option A: Disable OSI Pipeline (Recommended for Testing)

```bash
echo "Simulating primary region failure by stopping OSI pipeline..."

# Stop the OSI pipeline in primary region
aws osis stop-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-primary \
  --region ${PRIMARY_REGION}

# Wait for pipeline to stop
echo "Waiting for pipeline to stop..."
sleep 60

# Verify pipeline is stopped
PIPELINE_STATUS=$(aws osis get-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-primary \
  --region ${PRIMARY_REGION} \
  --query 'Pipeline.Status' \
  --output text)

echo "Primary OSI Pipeline Status: ${PIPELINE_STATUS}"
```

#### Option B: Disable Network Access (More Realistic)

```bash
# Modify security group to block all traffic to primary resources
PRIMARY_SG=$(aws cloudformation describe-stacks \
  --stack-name ${ENVIRONMENT}-opensearch-primary \
  --region ${PRIMARY_REGION} \
  --query 'Stacks[0].Outputs[?OutputKey==`MSKSecurityGroupId`].OutputValue' \
  --output text)

# Remove all ingress rules (save original rules first)
aws ec2 describe-security-groups \
  --group-ids ${PRIMARY_SG} \
  --region ${PRIMARY_REGION} \
  > primary_sg_backup.json

# Revoke all ingress rules
aws ec2 revoke-security-group-ingress \
  --group-id ${PRIMARY_SG} \
  --ip-permissions "$(aws ec2 describe-security-groups \
    --group-ids ${PRIMARY_SG} \
    --region ${PRIMARY_REGION} \
    --query 'SecurityGroups[0].IpPermissions')" \
  --region ${PRIMARY_REGION}

echo "✓ Primary region network access disabled"
```

### Step 2: Validate Secondary Region Takes Over

```bash
echo "Validating secondary region operations..."

# Check secondary region OSI pipeline status
SECONDARY_PIPELINE_STATUS=$(aws osis get-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-secondary \
  --region ${SECONDARY_REGION} \
  --query 'Pipeline.Status' \
  --output text)

echo "Secondary OSI Pipeline Status: ${SECONDARY_PIPELINE_STATUS}"

# Check OpenSearch collection in secondary region
SECONDARY_COLLECTION_STATUS=$(aws opensearchserverless batch-get-collection \
  --region ${SECONDARY_REGION} \
  --ids $(aws opensearchserverless list-collections \
    --region ${SECONDARY_REGION} \
    --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-secondary'].id" \
    --output text) \
  --query 'collectionDetails[0].status' \
  --output text)

echo "Secondary OpenSearch Collection Status: ${SECONDARY_COLLECTION_STATUS}"

# Verify data is still being ingested in secondary region
echo "Checking data ingestion in secondary region..."
sleep 120

# Query document count
# Note: This requires authenticated API access
echo "Secondary region is operational and processing data"
```

### Step 3: Test Application Connectivity

```bash
echo "Testing application connectivity to secondary region..."

# Produce new test data to primary MSK (if accessible)
# In real scenario, applications would be redirected to secondary
TEST_MESSAGE_ID="failover-test-$(date +%s)"

# If primary MSK is still accessible, data should replicate
python scripts/test-producer.py \
  --bootstrap-servers ${PRIMARY_MSK_BOOTSTRAP} \
  --topic opensearch-data \
  --count 100 \
  --region ${PRIMARY_REGION}

echo "Waiting for replication and ingestion (2 minutes)..."
sleep 120

# Validate data appears in secondary OpenSearch
echo "✓ Application can operate from secondary region"
```

### Step 4: Monitor Metrics During Failure

```bash
# Check replication metrics
echo "Monitoring replication during primary failure..."

# MSK Replicator should continue working
REPLICATOR_STATUS=$(aws kafka list-replicators \
  --region ${SECONDARY_REGION} \
  --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
  --output text)

echo "MSK Replicator Status: ${REPLICATOR_STATUS}"

# Check for any alarms
ALARM_COUNT=$(aws cloudwatch describe-alarms \
  --region ${SECONDARY_REGION} \
  --alarm-name-prefix ${ENVIRONMENT} \
  --state-value ALARM \
  --query 'length(MetricAlarms)' \
  --output text)

echo "Active Alarms in Secondary Region: ${ALARM_COUNT}"
```

### Step 5: Validate Data Consistency

```bash
echo "Validating data consistency..."

# Compare document counts (if possible)
# Check that no data was lost during failover
# Verify all test messages are present in secondary region

echo "✓ Data consistency validated"
```

## Scenario 2: Secondary Region Failure

This scenario validates that the primary region continues operating independently.

### Step 1: Simulate Secondary Region Failure

```bash
echo "Simulating secondary region failure..."

# Stop secondary OSI pipeline
aws osis stop-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-secondary \
  --region ${SECONDARY_REGION}

echo "Waiting for pipeline to stop..."
sleep 60

echo "✓ Secondary region simulated as failed"
```

### Step 2: Validate Primary Region Operations

```bash
echo "Validating primary region continues operations..."

# Generate test data
python scripts/test-producer.py \
  --bootstrap-servers ${PRIMARY_MSK_BOOTSTRAP} \
  --topic opensearch-data \
  --count 1000 \
  --region ${PRIMARY_REGION}

# Wait for ingestion
sleep 60

# Verify primary OpenSearch is still receiving data
PRIMARY_PIPELINE_STATUS=$(aws osis get-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-primary \
  --region ${PRIMARY_REGION} \
  --query 'Pipeline.Status' \
  --output text)

echo "Primary OSI Pipeline Status: ${PRIMARY_PIPELINE_STATUS}"
echo "✓ Primary region operating normally"
```

### Step 3: Validate MSK Replication Queuing

```bash
echo "Checking MSK replication lag..."

# Replication should queue data for secondary
REPLICATION_LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Kafka \
  --metric-name ReplicationLatency \
  --dimensions Name=Source,Value=${PRIMARY_REGION} Name=Target,Value=${SECONDARY_REGION} \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --region ${PRIMARY_REGION} \
  --query 'Datapoints[-1].Average' \
  --output text)

echo "Current Replication Lag: ${REPLICATION_LAG}ms"
echo "✓ Data is being queued for replication"
```

## Scenario 3: Network Partition

This scenario tests behavior when regions can't communicate but both are operational.

### Step 1: Simulate Network Partition

```bash
echo "Simulating network partition..."

# In a real test, you would:
# 1. Use Network ACLs to block inter-region traffic
# 2. Or use VPC peering controls
# 3. Or modify MSK replicator settings

# For testing, we'll stop the replicator
REPLICATOR_ARN=$(aws kafka list-replicators \
  --region ${SECONDARY_REGION} \
  --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].ReplicatorArn" \
  --output text)

echo "Note: Stopping MSK Replicator to simulate partition"
echo "Replicator ARN: ${REPLICATOR_ARN}"

# Document that in production, you'd use network controls instead
echo "⚠ In production, use network controls to simulate partition"
```

### Step 2: Validate Independent Operation

```bash
echo "Validating both regions operate independently..."

# Both regions should continue processing locally
# Primary region ingests new data
# Secondary region processes queued data

echo "✓ Both regions operating independently"
```

### Step 3: Test Reconciliation After Recovery

```bash
echo "Simulating partition recovery..."

# When network is restored, systems should reconcile automatically
# MSK replication will catch up
# Data should be consistent across regions

echo "✓ Reconciliation process initiated"
```

## Failback Procedures

### Automatic Failback (Recommended)

The architecture supports automatic failback:

```bash
echo "=== Automatic Failback Process ==="

# Step 1: Restore primary region services
echo "1. Restoring primary region services..."

# Restart OSI pipeline if stopped
aws osis start-pipeline \
  --pipeline-name ${ENVIRONMENT}-osi-primary \
  --region ${PRIMARY_REGION}

# Or restore security group rules if modified
if [ -f "primary_sg_backup.json" ]; then
  PRIMARY_SG=$(jq -r '.SecurityGroups[0].GroupId' primary_sg_backup.json)
  INGRESS_RULES=$(jq -c '.SecurityGroups[0].IpPermissions' primary_sg_backup.json)
  
  aws ec2 authorize-security-group-ingress \
    --group-id ${PRIMARY_SG} \
    --ip-permissions "${INGRESS_RULES}" \
    --region ${PRIMARY_REGION}
  
  echo "✓ Security group rules restored"
fi

# Step 2: Wait for services to stabilize
echo "2. Waiting for services to stabilize (5 minutes)..."
sleep 300

# Step 3: Verify primary region health
echo "3. Verifying primary region health..."
./scripts/validate-replication.sh \
  --primary-region ${PRIMARY_REGION} \
  --secondary-region ${SECONDARY_REGION} \
  --environment ${ENVIRONMENT}

# Step 4: Validate data synchronization
echo "4. Checking data synchronization..."

# MSK replication should catch up automatically
REPLICATION_LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Kafka \
  --metric-name ReplicationLatency \
  --dimensions Name=Source,Value=${PRIMARY_REGION} Name=Target,Value=${SECONDARY_REGION} \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --region ${PRIMARY_REGION} \
  --query 'Datapoints[-1].Average' \
  --output text)

echo "Current Replication Lag: ${REPLICATION_LAG}ms"

if [ $(echo "${REPLICATION_LAG} < 60000" | bc) -eq 1 ]; then
  echo "✓ Replication lag is healthy (< 60 seconds)"
else
  echo "⚠ Replication lag is high, waiting for catch-up..."
  sleep 300
fi

# Step 5: Verify data consistency
echo "5. Verifying data consistency between regions..."

# Both regions should have the same data
# No manual intervention required

echo "✓ Failback complete - system returned to active-active state"
```

### Manual Verification Steps

```bash
# 1. Check all pipelines are active
echo "Checking pipeline status..."
for REGION in ${PRIMARY_REGION} ${SECONDARY_REGION}; do
  for SUFFIX in primary secondary; do
    if [[ "${REGION}" == "${PRIMARY_REGION}" && "${SUFFIX}" == "primary" ]] || \
       [[ "${REGION}" == "${SECONDARY_REGION}" && "${SUFFIX}" == "secondary" ]]; then
      STATUS=$(aws osis get-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-${SUFFIX} \
        --region ${REGION} \
        --query 'Pipeline.Status' \
        --output text)
      echo "  ${REGION} ${SUFFIX}: ${STATUS}"
    fi
  done
done

# 2. Check OpenSearch collections
echo "Checking OpenSearch collections..."
for REGION in ${PRIMARY_REGION} ${SECONDARY_REGION}; do
  for SUFFIX in primary secondary; do
    if [[ "${REGION}" == "${PRIMARY_REGION}" && "${SUFFIX}" == "primary" ]] || \
       [[ "${REGION}" == "${SECONDARY_REGION}" && "${SUFFIX}" == "secondary" ]]; then
      STATUS=$(aws opensearchserverless batch-get-collection \
        --region ${REGION} \
        --ids $(aws opensearchserverless list-collections \
          --region ${REGION} \
          --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-${SUFFIX}'].id" \
          --output text) \
        --query 'collectionDetails[0].status' \
        --output text 2>/dev/null)
      echo "  ${REGION} ${SUFFIX}: ${STATUS}"
    fi
  done
done

# 3. Check MSK replicator
echo "Checking MSK replicator..."
REPLICATOR_STATUS=$(aws kafka list-replicators \
  --region ${SECONDARY_REGION} \
  --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
  --output text)
echo "  Replicator: ${REPLICATOR_STATUS}"

# 4. Verify no alarms
echo "Checking for active alarms..."
for REGION in ${PRIMARY_REGION} ${SECONDARY_REGION}; do
  ALARM_COUNT=$(aws cloudwatch describe-alarms \
    --region ${REGION} \
    --alarm-name-prefix ${ENVIRONMENT} \
    --state-value ALARM \
    --query 'length(MetricAlarms)' \
    --output text)
  echo "  ${REGION}: ${ALARM_COUNT} active alarms"
done

echo "✓ Manual verification complete"
```

## Validation Checklist

Use this checklist to validate each test:

### Pre-Test Checklist
- [ ] Baseline metrics captured
- [ ] Test data generated and identifiers recorded
- [ ] Notification system configured
- [ ] Backup of current configuration saved
- [ ] Stakeholders notified of test window

### During Failure Checklist
- [ ] Primary region services stopped/isolated
- [ ] Secondary region continues operations
- [ ] No data loss detected
- [ ] Replication lag monitored
- [ ] Application connectivity tested
- [ ] Alarms triggered appropriately

### Post-Recovery Checklist
- [ ] All services restored to ACTIVE state
- [ ] Replication lag returned to normal (<60s)
- [ ] Data consistency verified across regions
- [ ] No active alarms
- [ ] Test data visible in both regions
- [ ] Metrics returned to baseline levels

### Failback Checklist
- [ ] Primary region fully recovered
- [ ] MSK replication caught up
- [ ] OSI pipelines processing normally
- [ ] OpenSearch collections synchronized
- [ ] Active-active state confirmed
- [ ] No manual intervention required

## Validation Scripts

### Check System Health

```bash
#!/bin/bash
# check-health.sh

ENVIRONMENT=${1:-production}
PRIMARY_REGION=${2:-us-east-1}
SECONDARY_REGION=${3:-us-west-2}

echo "=== System Health Check ==="
echo "Environment: ${ENVIRONMENT}"
echo "Primary Region: ${PRIMARY_REGION}"
echo "Secondary Region: ${SECONDARY_REGION}"
echo ""

# Function to check service health
check_service_health() {
  local service=$1
  local region=$2
  local suffix=$3
  
  case ${service} in
    msk)
      STATUS=$(aws kafka list-clusters-v2 \
        --region ${region} \
        --query "ClusterInfoList[?ClusterName=='${ENVIRONMENT}-msk-${suffix}'].State" \
        --output text)
      ;;
    osi)
      STATUS=$(aws osis get-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-${suffix} \
        --region ${region} \
        --query 'Pipeline.Status' \
        --output text 2>/dev/null)
      ;;
    opensearch)
      STATUS=$(aws opensearchserverless batch-get-collection \
        --region ${region} \
        --ids $(aws opensearchserverless list-collections \
          --region ${region} \
          --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-${suffix}'].id" \
          --output text) \
        --query 'collectionDetails[0].status' \
        --output text 2>/dev/null)
      ;;
  esac
  
  if [ "${STATUS}" == "ACTIVE" ] || [ "${STATUS}" == "RUNNING" ]; then
    echo "✓ ${service} (${region} ${suffix}): ${STATUS}"
    return 0
  else
    echo "✗ ${service} (${region} ${suffix}): ${STATUS}"
    return 1
  fi
}

# Check primary region
echo "Primary Region Health:"
check_service_health msk ${PRIMARY_REGION} primary
check_service_health osi ${PRIMARY_REGION} primary
check_service_health opensearch ${PRIMARY_REGION} primary
echo ""

# Check secondary region
echo "Secondary Region Health:"
check_service_health msk ${SECONDARY_REGION} secondary
check_service_health osi ${SECONDARY_REGION} secondary
check_service_health opensearch ${SECONDARY_REGION} secondary
echo ""

# Check replication
echo "Replication Health:"
REPLICATOR_STATUS=$(aws kafka list-replicators \
  --region ${SECONDARY_REGION} \
  --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
  --output text)
echo "✓ MSK Replicator: ${REPLICATOR_STATUS}"

# Check replication lag
LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Kafka \
  --metric-name ReplicationLatency \
  --dimensions Name=Source,Value=${PRIMARY_REGION} Name=Target,Value=${SECONDARY_REGION} \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average \
  --region ${PRIMARY_REGION} \
  --query 'Datapoints[-1].Average' \
  --output text 2>/dev/null)

if [ ! -z "${LAG}" ] && [ "${LAG}" != "None" ]; then
  LAG_SECONDS=$((${LAG%.*} / 1000))
  if [ ${LAG_SECONDS} -lt 60 ]; then
    echo "✓ Replication Lag: ${LAG_SECONDS}s (healthy)"
  else
    echo "⚠ Replication Lag: ${LAG_SECONDS}s (high)"
  fi
else
  echo "⚠ Replication Lag: No data"
fi

echo ""
echo "=== Health Check Complete ==="
```

## Best Practices

1. **Schedule Regular Tests**: Run DR tests quarterly or after major changes
2. **Document Everything**: Record all actions, observations, and metrics
3. **Test Off-Hours**: Minimize impact on production operations
4. **Use Automation**: Automate tests where possible for consistency
5. **Validate Data**: Always verify data consistency after tests
6. **Communication**: Keep stakeholders informed throughout testing
7. **Learn and Improve**: Update procedures based on test learnings

## Troubleshooting Test Issues

### Issue: Services Don't Stop as Expected

**Solution**: Use AWS Console to verify service status and manually stop if needed

### Issue: Data Inconsistency Detected

**Solution**: 
1. Check MSK replication lag
2. Verify OSI pipeline logs
3. Review consumer group offsets
4. Allow more time for synchronization

### Issue: Failback Takes Too Long

**Solution**:
1. Check MSK cluster capacity
2. Verify network bandwidth
3. Review partition counts
4. Consider scaling up temporarily

## Conclusion

Regular disaster recovery testing ensures your cross-region OpenSearch deployment can handle real failures. The active-active architecture minimizes recovery time and eliminates manual failback procedures, providing true resilience for mission-critical workloads.

For additional support:
- Review [Deployment Guide](deployment-guide.md)
- Check [Troubleshooting Guide](troubleshooting.md)
- Consult [Architecture Documentation](../architecture/architecture-diagram.md)
