#!/bin/bash
# validate-replication.sh
# Script to validate cross-region replication for OpenSearch MSK solution

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
ENVIRONMENT="${ENVIRONMENT:-production}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Cross-Region Replication Validator${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to print success message
success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print error message
error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to print warning message
warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to print info message
info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    info "Checking AWS CLI installation..."
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed"
        exit 1
    fi
    success "AWS CLI is installed"
}

# Function to get stack outputs
get_stack_output() {
    local region=$1
    local stack_name=$2
    local output_key=$3
    
    aws cloudformation describe-stacks \
        --region "$region" \
        --stack-name "$stack_name" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# Function to validate MSK cluster
validate_msk_cluster() {
    local region=$1
    local cluster_name=$2
    
    info "Validating MSK cluster in $region..."
    
    local cluster_arn=$(aws kafka list-clusters-v2 \
        --region "$region" \
        --query "ClusterInfoList[?ClusterName=='${ENVIRONMENT}-msk-${cluster_name}'].ClusterArn" \
        --output text 2>/dev/null)
    
    if [ -z "$cluster_arn" ]; then
        error "MSK cluster not found in $region"
        return 1
    fi
    
    local state=$(aws kafka describe-cluster-v2 \
        --region "$region" \
        --cluster-arn "$cluster_arn" \
        --query 'ClusterInfo.State' \
        --output text)
    
    if [ "$state" = "ACTIVE" ]; then
        success "MSK cluster is ACTIVE in $region"
        return 0
    else
        warning "MSK cluster state: $state in $region"
        return 1
    fi
}

# Function to validate OpenSearch collection
validate_opensearch_collection() {
    local region=$1
    local collection_name=$2
    
    info "Validating OpenSearch collection in $region..."
    
    local collection_id=$(aws opensearchserverless list-collections \
        --region "$region" \
        --query "collectionSummaries[?name=='${ENVIRONMENT}-opensearch-${collection_name}'].id" \
        --output text 2>/dev/null)
    
    if [ -z "$collection_id" ]; then
        error "OpenSearch collection not found in $region"
        return 1
    fi
    
    local status=$(aws opensearchserverless batch-get-collection \
        --region "$region" \
        --ids "$collection_id" \
        --query 'collectionDetails[0].status' \
        --output text)
    
    if [ "$status" = "ACTIVE" ]; then
        success "OpenSearch collection is ACTIVE in $region"
        return 0
    else
        warning "OpenSearch collection status: $status in $region"
        return 1
    fi
}

# Function to validate OSI pipeline
validate_osi_pipeline() {
    local region=$1
    local pipeline_name=$2
    
    info "Validating OSI pipeline in $region..."
    
    local pipeline_status=$(aws osis list-pipelines \
        --region "$region" \
        --query "Pipelines[?PipelineName=='${ENVIRONMENT}-osi-${pipeline_name}'].Status" \
        --output text 2>/dev/null)
    
    if [ -z "$pipeline_status" ]; then
        error "OSI pipeline not found in $region"
        return 1
    fi
    
    if [ "$pipeline_status" = "ACTIVE" ]; then
        success "OSI pipeline is ACTIVE in $region"
        return 0
    else
        warning "OSI pipeline status: $pipeline_status in $region"
        return 1
    fi
}

# Function to check MSK replication lag
check_replication_lag() {
    info "Checking MSK replication lag..."
    
    local lag=$(aws cloudwatch get-metric-statistics \
        --region "$PRIMARY_REGION" \
        --namespace AWS/Kafka \
        --metric-name ReplicationLatency \
        --dimensions Name=Source,Value="$PRIMARY_REGION" Name=Target,Value="$SECONDARY_REGION" \
        --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
        --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        --period 300 \
        --statistics Average \
        --query 'Datapoints[-1].Average' \
        --output text 2>/dev/null)
    
    if [ -z "$lag" ] || [ "$lag" = "None" ]; then
        warning "No replication lag data available (this is normal for new deployments)"
    else
        lag_seconds=$((lag / 1000))
        if [ "$lag_seconds" -lt 60 ]; then
            success "Replication lag: ${lag_seconds}s (healthy)"
        else
            warning "Replication lag: ${lag_seconds}s (consider investigating)"
        fi
    fi
}

# Function to get document count from OpenSearch
get_document_count() {
    local region=$1
    local collection_endpoint=$2
    
    # Note: This requires proper authentication setup
    # In practice, you'd use AWS signature or temporary credentials
    info "Checking document count in $region..."
    warning "Document count check requires authenticated access (skipping automated check)"
    echo "   Use AWS console or authenticated API calls to verify document counts"
}

# Function to validate MSK replicator
validate_msk_replicator() {
    info "Validating MSK Replicator..."
    
    local replicator_status=$(aws kafka list-replicators \
        --region "$SECONDARY_REGION" \
        --query "Replicators[?ReplicatorName=='${ENVIRONMENT}-msk-replicator'].State" \
        --output text 2>/dev/null)
    
    if [ -z "$replicator_status" ]; then
        error "MSK Replicator not found"
        return 1
    fi
    
    if [ "$replicator_status" = "RUNNING" ]; then
        success "MSK Replicator is RUNNING"
        return 0
    else
        warning "MSK Replicator status: $replicator_status"
        return 1
    fi
}

# Function to check CloudWatch alarms
check_alarms() {
    local region=$1
    local alarm_prefix=$2
    
    info "Checking CloudWatch alarms in $region..."
    
    local alarm_count=$(aws cloudwatch describe-alarms \
        --region "$region" \
        --alarm-name-prefix "$alarm_prefix" \
        --state-value ALARM \
        --query 'length(MetricAlarms)' \
        --output text 2>/dev/null)
    
    if [ "$alarm_count" -eq 0 ]; then
        success "No alarms in ALARM state in $region"
    else
        warning "$alarm_count alarm(s) in ALARM state in $region"
        aws cloudwatch describe-alarms \
            --region "$region" \
            --alarm-name-prefix "$alarm_prefix" \
            --state-value ALARM \
            --query 'MetricAlarms[*].[AlarmName,StateReason]' \
            --output table
    fi
}

# Main validation flow
main() {
    echo ""
    info "Starting validation..."
    echo ""
    
    # Check prerequisites
    check_aws_cli
    echo ""
    
    # Validate Primary Region
    echo -e "${BLUE}=== Primary Region ($PRIMARY_REGION) ===${NC}"
    validate_msk_cluster "$PRIMARY_REGION" "primary"
    validate_opensearch_collection "$PRIMARY_REGION" "primary"
    validate_osi_pipeline "$PRIMARY_REGION" "primary"
    check_alarms "$PRIMARY_REGION" "$ENVIRONMENT"
    echo ""
    
    # Validate Secondary Region
    echo -e "${BLUE}=== Secondary Region ($SECONDARY_REGION) ===${NC}"
    validate_msk_cluster "$SECONDARY_REGION" "secondary"
    validate_opensearch_collection "$SECONDARY_REGION" "secondary"
    validate_osi_pipeline "$SECONDARY_REGION" "secondary"
    validate_msk_replicator
    check_alarms "$SECONDARY_REGION" "$ENVIRONMENT"
    echo ""
    
    # Check replication
    echo -e "${BLUE}=== Replication Status ===${NC}"
    check_replication_lag
    echo ""
    
    # Summary
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✓ Validation Complete${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    info "Next Steps:"
    echo "  1. Produce test data: python scripts/test-producer.py --bootstrap-servers <MSK_ENDPOINT> --count 1000"
    echo "  2. Verify data in both regions using OpenSearch Dashboards"
    echo "  3. Monitor CloudWatch metrics for replication lag"
    echo "  4. Test failover by stopping primary region resources"
    echo ""
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --primary-region)
            PRIMARY_REGION="$2"
            shift 2
            ;;
        --secondary-region)
            SECONDARY_REGION="$2"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --primary-region REGION      Primary AWS region (default: us-east-1)"
            echo "  --secondary-region REGION    Secondary AWS region (default: us-west-2)"
            echo "  --environment NAME           Environment name (default: production)"
            echo "  -h, --help                   Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  PRIMARY_REGION              Override primary region"
            echo "  SECONDARY_REGION            Override secondary region"
            echo "  ENVIRONMENT                 Override environment name"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main
