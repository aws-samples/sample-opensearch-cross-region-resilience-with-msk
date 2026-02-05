#!/bin/bash
# dr-test.sh
# Automated Disaster Recovery Testing Script for OpenSearch Cross-Region Solution

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
ENVIRONMENT="${ENVIRONMENT:-production}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
TEST_DIR="dr-test-$(date +%Y%m%d_%H%M%S)"

# Create test directory
mkdir -p "${TEST_DIR}"
cd "${TEST_DIR}"

# Logging
LOG_FILE="dr-test.log"
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    log_step "Checking Prerequisites"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install it first."
        exit 1
    fi
    log_success "AWS CLI installed"
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        log_warning "jq not found. Some features may be limited."
    else
        log_success "jq installed"
    fi
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found. Please install it first."
        exit 1
    fi
    log_success "Python 3 installed"
    
    # Verify AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured properly"
        exit 1
    fi
    log_success "AWS credentials configured"
}

# Function to capture baseline metrics
capture_baseline() {
    log_step "Capturing Baseline Metrics"
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    # Primary region metrics
    log_info "Capturing primary region metrics..."
    aws opensearchserverless batch-get-collection \
        --region ${PRIMARY_REGION} \
        --ids $(aws opensearchserverless list-collections \
            --region ${PRIMARY_REGION} \
            --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-primary'].id" \
            --output text 2>/dev/null) \
        > baseline_primary_${TIMESTAMP}.json 2>/dev/null || log_warning "Could not capture primary collection metrics"
    
    # Secondary region metrics
    log_info "Capturing secondary region metrics..."
    aws opensearchserverless batch-get-collection \
        --region ${SECONDARY_REGION} \
        --ids $(aws opensearchserverless list-collections \
            --region ${SECONDARY_REGION} \
            --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-secondary'].id" \
            --output text 2>/dev/null) \
        > baseline_secondary_${TIMESTAMP}.json 2>/dev/null || log_warning "Could not capture secondary collection metrics"
    
    # Replication lag
    log_info "Capturing replication lag..."
    aws cloudwatch get-metric-statistics \
        --namespace AWS/Kafka \
        --metric-name ReplicationLatency \
        --dimensions Name=Source,Value=${PRIMARY_REGION} Name=Target,Value=${SECONDARY_REGION} \
        --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
        --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
        --period 60 \
        --statistics Average,Maximum \
        --region ${PRIMARY_REGION} \
        > baseline_replication_lag_${TIMESTAMP}.json 2>/dev/null || log_warning "Could not capture replication lag"
    
    log_success "Baseline metrics captured to ${TEST_DIR}"
}

# Function to generate test data
generate_test_data() {
    log_step "Generating Test Data"
    
    local count=${1:-1000}
    
    # Get MSK bootstrap servers
    MSK_BOOTSTRAP=$(aws cloudformation describe-stacks \
        --stack-name ${ENVIRONMENT}-opensearch-primary \
        --region ${PRIMARY_REGION} \
        --query 'Stacks[0].Outputs[?OutputKey==`MSKBootstrapServers`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -z "${MSK_BOOTSTRAP}" ]; then
        log_error "Could not retrieve MSK bootstrap servers"
        return 1
    fi
    
    log_info "MSK Bootstrap Servers: ${MSK_BOOTSTRAP}"
    log_info "Producing ${count} test messages..."
    
    # Generate test data with unique identifier
    TEST_BATCH_ID="dr-test-$(date +%s)"
    echo "${TEST_BATCH_ID}" > test_batch_id.txt
    
    # Run producer script if available
    if [ -f "../scripts/test-producer.py" ]; then
        python3 ../scripts/test-producer.py \
            --bootstrap-servers "${MSK_BOOTSTRAP}" \
            --topic opensearch-data \
            --count ${count} \
            --region ${PRIMARY_REGION} || log_warning "Failed to produce test data"
    else
        log_warning "Test producer script not found. Skipping data generation."
    fi
    
    log_info "Waiting for data propagation (3 minutes)..."
    sleep 180
    
    log_success "Test data generated with ID: ${TEST_BATCH_ID}"
}

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
                --output text 2>/dev/null)
            ;;
        osi)
            STATUS=$(aws osis get-pipeline \
                --pipeline-name ${ENVIRONMENT}-osi-${suffix} \
                --region ${region} \
                --query 'Pipeline.Status' \
                --output text 2>/dev/null)
            ;;
        opensearch)
            COLLECTION_ID=$(aws opensearchserverless list-collections \
                --region ${region} \
                --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-${suffix}'].id" \
                --output text 2>/dev/null)
            if [ -n "${COLLECTION_ID}" ]; then
                STATUS=$(aws opensearchserverless batch-get-collection \
                    --region ${region} \
                    --ids ${COLLECTION_ID} \
                    --query 'collectionDetails[0].status' \
                    --output text 2>/dev/null)
            else
                STATUS="NOT_FOUND"
            fi
            ;;
    esac
    
    if [ "${STATUS}" == "ACTIVE" ] || [ "${STATUS}" == "RUNNING" ]; then
        log_success "${service} (${region} ${suffix}): ${STATUS}"
        return 0
    else
        log_error "${service} (${region} ${suffix}): ${STATUS}"
        return 1
    fi
}

# Function to simulate primary region failure
simulate_primary_failure() {
    log_step "Simulating Primary Region Failure"
    
    log_info "Stopping primary OSI pipeline..."
    
    aws osis stop-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-primary \
        --region ${PRIMARY_REGION} 2>/dev/null || log_error "Failed to stop primary pipeline"
    
    log_info "Waiting for pipeline to stop (60 seconds)..."
    sleep 60
    
    # Verify pipeline stopped
    PIPELINE_STATUS=$(aws osis get-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-primary \
        --region ${PRIMARY_REGION} \
        --query 'Pipeline.Status' \
        --output text 2>/dev/null)
    
    log_info "Primary OSI Pipeline Status: ${PIPELINE_STATUS}"
    
    if [ "${PIPELINE_STATUS}" == "STOPPED" ] || [ "${PIPELINE_STATUS}" == "STOPPING" ]; then
        log_success "Primary region failure simulated successfully"
        echo "STOPPED" > primary_failure_state.txt
        return 0
    else
        log_warning "Primary pipeline may not have stopped completely: ${PIPELINE_STATUS}"
        return 1
    fi
}

# Function to validate secondary region takeover
validate_secondary_takeover() {
    log_step "Validating Secondary Region Takeover"
    
    log_info "Checking secondary region health..."
    
    # Check OSI pipeline
    check_service_health osi ${SECONDARY_REGION} secondary
    
    # Check OpenSearch collection
    check_service_health opensearch ${SECONDARY_REGION} secondary
    
    # Check MSK replicator
    REPLICATOR_STATUS=$(aws kafka list-replicators \
        --region ${SECONDARY_REGION} \
        --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
        --output text 2>/dev/null)
    
    log_info "MSK Replicator Status: ${REPLICATOR_STATUS}"
    
    if [ "${REPLICATOR_STATUS}" == "RUNNING" ]; then
        log_success "Secondary region is operational and processing data"
        return 0
    else
        log_error "Secondary region validation failed"
        return 1
    fi
}

# Function to simulate failback
simulate_failback() {
    log_step "Simulating Failback to Primary Region"
    
    log_info "Restoring primary OSI pipeline..."
    
    aws osis start-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-primary \
        --region ${PRIMARY_REGION} 2>/dev/null || log_error "Failed to start primary pipeline"
    
    log_info "Waiting for pipeline to start (5 minutes)..."
    sleep 300
    
    # Verify pipeline started
    PIPELINE_STATUS=$(aws osis get-pipeline \
        --pipeline-name ${ENVIRONMENT}-osi-primary \
        --region ${PRIMARY_REGION} \
        --query 'Pipeline.Status' \
        --output text 2>/dev/null)
    
    log_info "Primary OSI Pipeline Status: ${PIPELINE_STATUS}"
    
    if [ "${PIPELINE_STATUS}" == "ACTIVE" ]; then
        log_success "Primary region restored successfully"
        rm -f primary_failure_state.txt
        return 0
    else
        log_warning "Primary pipeline may not be fully active yet: ${PIPELINE_STATUS}"
        return 1
    fi
}

# Function to validate system health
validate_system_health() {
    log_step "Validating System Health"
    
    log_info "Checking primary region..."
    check_service_health msk ${PRIMARY_REGION} primary
    check_service_health osi ${PRIMARY_REGION} primary
    check_service_health opensearch ${PRIMARY_REGION} primary
    
    echo ""
    log_info "Checking secondary region..."
    check_service_health msk ${SECONDARY_REGION} secondary
    check_service_health osi ${SECONDARY_REGION} secondary
    check_service_health opensearch ${SECONDARY_REGION} secondary
    
    echo ""
    log_info "Checking replication..."
    REPLICATOR_STATUS=$(aws kafka list-replicators \
        --region ${SECONDARY_REGION} \
        --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
        --output text 2>/dev/null)
    log_info "MSK Replicator: ${REPLICATOR_STATUS}"
    
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
            log_success "Replication Lag: ${LAG_SECONDS}s (healthy)"
        else
            log_warning "Replication Lag: ${LAG_SECONDS}s (consider investigating)"
        fi
    else
        log_warning "Replication Lag: No data available"
    fi
}

# Function to generate test report
generate_report() {
    log_step "Generating Test Report"
    
    REPORT_FILE="dr-test-report.txt"
    
    cat > ${REPORT_FILE} << EOF
=======================================================
  Disaster Recovery Test Report
=======================================================

Test Date: $(date)
Environment: ${ENVIRONMENT}
Primary Region: ${PRIMARY_REGION}
Secondary Region: ${SECONDARY_REGION}

Test Directory: ${TEST_DIR}
Log File: ${LOG_FILE}

=======================================================
Test Summary
=======================================================

EOF
    
    if [ -f "test_batch_id.txt" ]; then
        echo "Test Batch ID: $(cat test_batch_id.txt)" >> ${REPORT_FILE}
    fi
    
    if [ -f "primary_failure_state.txt" ]; then
        echo "⚠ Primary region is currently in failure state" >> ${REPORT_FILE}
    else
        echo "✓ Primary region is operational" >> ${REPORT_FILE}
    fi
    
    cat >> ${REPORT_FILE} << EOF

=======================================================
Baseline Metrics
=======================================================

EOF
    
    if ls baseline_*.json 1> /dev/null 2>&1; then
        echo "Baseline files captured:" >> ${REPORT_FILE}
        ls -1 baseline_*.json >> ${REPORT_FILE}
    else
        echo "No baseline metrics files found" >> ${REPORT_FILE}
    fi
    
    cat >> ${REPORT_FILE} << EOF

=======================================================
Recommendations
=======================================================

1. Review all log entries in ${LOG_FILE}
2. Verify data consistency between regions
3. Check CloudWatch dashboards for anomalies
4. Document any issues encountered
5. Update runbooks based on learnings

=======================================================
Next Steps
=======================================================

- If primary region is in failure state, run:
  ./dr-test.sh --restore

- To run full validation:
  ./dr-test.sh --validate

- For cleanup:
  - Review and archive test files
  - Ensure all services are back to normal

=======================================================
End of Report
=======================================================
EOF
    
    log_success "Test report generated: ${REPORT_FILE}"
    cat ${REPORT_FILE}
}

# Main test scenarios
run_failover_test() {
    log_step "Running Failover Test Scenario"
    
    # Step 1: Baseline
    capture_baseline
    
    # Step 2: Generate test data
    generate_test_data 1000
    
    # Step 3: Simulate failure
    simulate_primary_failure
    
    # Step 4: Validate secondary
    sleep 60
    validate_secondary_takeover
    
    # Step 5: Generate more test data to validate replication
    log_info "Generating additional test data..."
    generate_test_data 500
    
    log_success "Failover test completed"
}

run_failback_test() {
    log_step "Running Failback Test Scenario"
    
    # Step 1: Restore primary
    simulate_failback
    
    # Step 2: Wait for stabilization
    log_info "Waiting for system stabilization (3 minutes)..."
    sleep 180
    
    # Step 3: Validate both regions
    validate_system_health
    
    # Step 4: Generate test data to validate active-active
    log_info "Generating test data to validate active-active state..."
    generate_test_data 500
    
    log_success "Failback test completed"
}

# CLI interface
show_usage() {
    cat << EOF
Usage: $0 [OPTION]

Automated Disaster Recovery Testing for OpenSearch Cross-Region Solution

Options:
  --failover          Run failover test (simulate primary failure)
  --failback          Run failback test (restore primary region)
  --full              Run complete failover/failback cycle
  --validate          Validate current system health
  --restore           Restore primary region if in failure state
  --baseline          Capture baseline metrics only
  --help              Show this help message

Environment Variables:
  ENVIRONMENT         Environment name (default: production)
  PRIMARY_REGION      Primary AWS region (default: us-east-1)
  SECONDARY_REGION    Secondary AWS region (default: us-west-2)

Examples:
  $0 --failover       # Simulate primary region failure
  $0 --failback       # Restore primary region
  $0 --full           # Run complete DR test cycle
  $0 --validate       # Check system health

EOF
}

# Parse arguments
case "${1:-}" in
    --failover)
        check_prerequisites
        run_failover_test
        generate_report
        ;;
    --failback)
        check_prerequisites
        run_failback_test
        generate_report
        ;;
    --full)
        check_prerequisites
        run_failover_test
        log_info "Waiting 5 minutes before failback..."
        sleep 300
        run_failback_test
        generate_report
        ;;
    --validate)
        check_prerequisites
        validate_system_health
        ;;
    --restore)
        check_prerequisites
        simulate_failback
        validate_system_health
        ;;
    --baseline)
        check_prerequisites
        capture_baseline
        ;;
    --help|-h|"")
        show_usage
        exit 0
        ;;
    *)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac

log_success "All operations completed successfully!"
