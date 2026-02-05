# Achieve Cross-Region Resilience with Amazon OpenSearch Ingestion and Amazon MSK

Cross-Region deployments provide increased resilience to maintain business continuity during outages, natural disasters, or other operational interruptions. This post extends the [original cross-Region resilience solution](https://aws.amazon.com/blogs/big-data/achieve-cross-region-resilience-with-amazon-opensearch-ingestion/) by using Amazon Managed Streaming for Apache Kafka (Amazon MSK) with its built-in replication feature for true active-active data replication.

## Solution Overview

This solution uses Amazon MSK Replicator for bidirectional cross-Region data replication, combined with OpenSearch Ingestion (OSI) pipelines to index data into OpenSearch Serverless collections in each Region. Unlike the S3-based approach, MSK Replicator provides near real-time replication with IDENTICAL topic naming, enabling seamless active-active operations.

**Data Flow:**
1. Data sources write to the local MSK cluster in their Region
2. MSK Replicator replicates data bidirectionally between Regions using IDENTICAL topic naming
3. OSI pipelines in each Region consume from the local MSK cluster and write to the local OpenSearch Serverless collection
4. Both OpenSearch collections contain the same data from both Regions

## Prerequisites

Complete the following prerequisite steps:

1. **Deploy VPC Infrastructure in both Regions**
   - Create VPCs with private subnets in at least 3 Availability Zones
   - Configure NAT Gateways for outbound internet access from private subnets
   - Use non-overlapping CIDR blocks (e.g., 10.0.0.0/16 for primary, 10.1.0.0/16 for secondary)

2. **Deploy OpenSearch Serverless collections in both Regions**
   - Create TIMESERIES type collections for log data
   - Configure encryption, network, and data access policies
   - Create VPC endpoints for private access

3. **Deploy MSK clusters in both Regions**
   - Use Kafka version 3.6.0 or later
   - Enable IAM authentication (SASL/IAM)
   - Enable multi-VPC connectivity (required for MSK Replicator and OSI)
   - Configure MSK cluster policies to allow `kafka.amazonaws.com` and `osis-pipelines.amazonaws.com` service principals

4. **Configure IAM permissions**
   - Create IAM roles for OSI pipelines with MSK and OpenSearch access
   - Create IAM roles for MSK Replicator with cross-Region cluster access
   - Ensure proper resource ARN patterns for topics and consumer groups

## Use OpenSearch Ingestion (OSI) for Cross-Region Writes

In this solution, OSI pipelines consume data from the local MSK cluster and write to the local OpenSearch Serverless collection. MSK Replicator handles the cross-Region data synchronization.

### OSI Pipeline Configuration

The OSI pipeline uses MSK as a source with IAM authentication:

```yaml
version: "2"
kafka-pipeline:
  source:
    kafka:
      acknowledgments: true
      topics:
        - name: "opensearch-data"
          group_id: "osi-consumer-group-primary"
      aws:
        msk:
          arn: "arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/CLUSTER_ID"
        region: "us-east-1"
        sts_role_arn: "arn:aws:iam::ACCOUNT_ID:role/production-osi-pipeline-primary-role"
  sink:
    - opensearch:
        hosts:
          - "https://COLLECTION_ID.us-east-1.aoss.amazonaws.com"
        index: "application-logs-${yyyy.MM.dd}"
        aws:
          serverless: true
          region: "us-east-1"
          sts_role_arn: "arn:aws:iam::ACCOUNT_ID:role/production-osi-pipeline-primary-role"
        dlq:
          s3:
            bucket: "production-opensearch-dlq-us-east-1"
            region: "us-east-1"
            sts_role_arn: "arn:aws:iam::ACCOUNT_ID:role/production-osi-pipeline-primary-role"
```

### IAM Role for OSI Pipeline

The OSI pipeline role requires permissions for MSK, OpenSearch Serverless, and S3 (for DLQ):

```yaml
OSIPipelineRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: production-osi-pipeline-primary-role
    AssumeRolePolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Service: osis-pipelines.amazonaws.com
          Action: 'sts:AssumeRole'
    Policies:
      - PolicyName: MSKAccess
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action:
                - 'kafka-cluster:Connect'
                - 'kafka-cluster:DescribeCluster'
                - 'kafka-cluster:ReadData'
                - 'kafka-cluster:DescribeTopic'
                - 'kafka-cluster:DescribeGroup'
                - 'kafka-cluster:AlterGroup'
              Resource:
                - 'arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/*'
      - PolicyName: OpenSearchAccess
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            - Effect: Allow
              Action:
                - 'aoss:APIAccessAll'
                - 'aoss:BatchGetCollection'
              Resource: 'arn:aws:aoss:us-east-1:ACCOUNT_ID:collection/*'
```

## Use Amazon MSK for Cross-Region Writes

Instead of S3 cross-Region replication, this solution uses Amazon MSK Replicator for bidirectional data replication. MSK Replicator provides:

- **Near real-time replication** between MSK clusters across Regions
- **IDENTICAL topic naming** mode to maintain the same topic names in both Regions
- **Automatic loop prevention** using Kafka headers to prevent infinite replication
- **Consumer group offset synchronization** for seamless failover

### MSK Replicator Configuration

For true active-active replication, deploy TWO MSK Replicators:

**Replicator 1: Primary → Secondary (deployed in us-west-2)**
```yaml
MSKReplicator:
  Type: AWS::MSK::Replicator
  Properties:
    ReplicatorName: production-primary-to-secondary
    Description: Active-Active replication from primary to secondary with identical topic names
    ServiceExecutionRoleArn: !GetAtt MSKReplicatorRole.Arn
    KafkaClusters:
      - AmazonMskCluster:
          MskClusterArn: "arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/CLUSTER_ID"
        VpcConfig:
          SubnetIds:
            - subnet-primary-1
            - subnet-primary-2
            - subnet-primary-3
          SecurityGroupIds:
            - sg-primary-msk
      - AmazonMskCluster:
          MskClusterArn: "arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/CLUSTER_ID"
        VpcConfig:
          SubnetIds:
            - subnet-secondary-1
            - subnet-secondary-2
            - subnet-secondary-3
          SecurityGroupIds:
            - sg-secondary-msk
    ReplicationInfoList:
      - SourceKafkaClusterArn: "arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/CLUSTER_ID"
        TargetKafkaClusterArn: "arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/CLUSTER_ID"
        TargetCompressionType: SNAPPY
        TopicReplication:
          TopicsToReplicate:
            - opensearch-data
          CopyTopicConfigurations: true
          CopyAccessControlListsForTopics: false
          DetectAndCopyNewTopics: true
          TopicNameConfiguration:
            Type: IDENTICAL
        ConsumerGroupReplication:
          ConsumerGroupsToReplicate:
            - '.*'
          DetectAndCopyNewConsumerGroups: true
```

**Replicator 2: Secondary → Primary (deployed in us-east-1)**

Deploy a second replicator with source and target reversed for bidirectional replication.

### IAM Role for MSK Replicator

```yaml
MSKReplicatorRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: production-msk-replicator-role
    AssumeRolePolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Service: kafka.amazonaws.com
          Action: 'sts:AssumeRole'
    Policies:
      - PolicyName: MSKReplicatorPolicy
        PolicyDocument:
          Version: '2012-10-17'
          Statement:
            # Cluster-level permissions
            - Effect: Allow
              Action:
                - 'kafka-cluster:Connect'
                - 'kafka-cluster:DescribeCluster'
                - 'kafka-cluster:AlterCluster'
                - 'kafka-cluster:DescribeClusterDynamicConfiguration'
              Resource:
                - 'arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/*'
                - 'arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/*'
            # Topic-level permissions
            - Effect: Allow
              Action:
                - 'kafka-cluster:ReadData'
                - 'kafka-cluster:DescribeTopic'
                - 'kafka-cluster:WriteData'
                - 'kafka-cluster:CreateTopic'
                - 'kafka-cluster:AlterTopic'
              Resource:
                - 'arn:aws:kafka:us-east-1:ACCOUNT_ID:topic/production-msk-primary/*'
                - 'arn:aws:kafka:us-west-2:ACCOUNT_ID:topic/production-msk-secondary/*'
            # Consumer group permissions
            - Effect: Allow
              Action:
                - 'kafka-cluster:DescribeGroup'
                - 'kafka-cluster:AlterGroup'
                - 'kafka-cluster:DeleteGroup'
              Resource:
                - 'arn:aws:kafka:us-east-1:ACCOUNT_ID:group/production-msk-primary/*'
                - 'arn:aws:kafka:us-west-2:ACCOUNT_ID:group/production-msk-secondary/*'
```

### MSK Cluster Policy

Each MSK cluster requires a cluster policy to allow MSK Replicator and OSI to connect:

```yaml
MSKClusterPolicy:
  Type: AWS::MSK::ClusterPolicy
  Properties:
    ClusterArn: !Ref MSKCluster
    Policy:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Service: osis-pipelines.amazonaws.com
          Action:
            - 'kafka:CreateVpcConnection'
            - 'kafka:GetBootstrapBrokers'
            - 'kafka:DescribeCluster'
            - 'kafka:DescribeClusterV2'
          Resource: !Ref MSKCluster
        - Effect: Allow
          Principal:
            Service: kafka.amazonaws.com
          Action:
            - 'kafka:CreateVpcConnection'
            - 'kafka:GetBootstrapBrokers'
            - 'kafka:DescribeCluster'
            - 'kafka:DescribeClusterV2'
          Resource: !Ref MSKCluster
```

### Security Group Configuration

For MSK Replicator to work across Regions, security groups must allow traffic between VPCs:

**Primary MSK Security Group (us-east-1):**
- Ingress: Allow all traffic from secondary VPC CIDR (10.1.0.0/16)
- Ingress: Allow port 9098 from self (for IAM authentication)
- Egress: Allow all traffic to 0.0.0.0/0

**Secondary MSK Security Group (us-west-2):**
- Ingress: Allow all traffic from primary VPC CIDR (10.0.0.0/16)
- Ingress: Allow port 9098 from self (for IAM authentication)
- Egress: Allow all traffic to 0.0.0.0/0

## Impairment Scenarios and Additional Considerations

### Regional Impairment Scenario

When a Region is impaired, applications can failover to the OpenSearch Serverless collection in the other Region and continue operations without interruption. The data present before the impairment is available in both collections because:

1. **MSK Replicator** continuously replicates data bidirectionally with near real-time latency
2. **IDENTICAL topic naming** ensures the same topic name exists in both Regions
3. **Consumer group offset synchronization** allows consumers to resume from the correct position

### Failback Process

When the impaired Region recovers:

1. MSK Replicator automatically resumes replication from where it left off
2. Any data written to the healthy Region during the impairment is backfilled to the recovered Region
3. OSI pipelines in the recovered Region resume consuming and indexing data
4. No manual reconfiguration is required

### Key Differences from S3-Based Solution

| Aspect | S3-Based Solution | MSK-Based Solution |
|--------|-------------------|-------------------|
| Replication Latency | Minutes (S3 replication SLA) | Near real-time (seconds) |
| Data Durability | S3 buckets contain full data | MSK topics contain streaming data |
| Complexity | Simpler (S3 replication is managed) | More complex (requires MSK Replicator setup) |
| Cost | S3 storage + replication costs | MSK cluster + replicator costs |
| Use Case | Batch/near-real-time workloads | Real-time streaming workloads |

### Additional Considerations

1. **Cross-Region Data Transfer Costs**: MSK Replicator incurs cross-Region data transfer costs. Monitor replication throughput and optimize topic configurations.

2. **Dead-Letter Queues**: Always configure DLQ for OSI pipelines to capture failed documents:
   ```yaml
   dlq:
     s3:
       bucket: "production-opensearch-dlq-us-east-1"
       region: "us-east-1"
       sts_role_arn: "arn:aws:iam::ACCOUNT_ID:role/production-osi-pipeline-role"
   ```

3. **Multi-VPC Connectivity**: Enable multi-VPC connectivity on MSK clusters before deploying OSI pipelines. This operation takes 15-25 minutes.

4. **MSK Replicator Creation Time**: MSK Replicator can take 15-30 minutes to create. Deploy separately from other resources to avoid CloudFormation timeouts.

5. **Topic Naming Mode**: Use IDENTICAL mode for active-active scenarios. MSK Replicator uses Kafka headers to prevent infinite replication loops.

6. **Monitoring**: Monitor these CloudWatch metrics:
   - `AWS/KafkaReplicator/ReplicationLatency` - Replication lag between clusters
   - `AWS/OSIS/DocumentsFailed` - Failed document ingestion
   - `AWS/Kafka/MessagesInPerSec` - Message throughput

### Resource Creation Times

| Resource | Creation Time |
|----------|--------------|
| VPC Infrastructure | ~10 minutes |
| MSK Cluster | 25-35 minutes |
| Multi-VPC Connectivity | 15-25 minutes |
| OpenSearch Serverless Collection | 2-3 minutes |
| OSI Pipeline | 5-10 minutes |
| MSK Replicator | 15-30 minutes |
| **Total Deployment** | **~2.5-3.5 hours** |

## Conclusion

This solution extends the cross-Region resilience architecture by using Amazon MSK Replicator for near real-time bidirectional data replication. The combination of MSK Replicator with IDENTICAL topic naming and OSI pipelines provides a robust active-active architecture that:

- Maintains data consistency across Regions with minimal latency
- Automatically resumes replication after Regional recovery
- Requires no manual reconfiguration during failover or failback
- Supports real-time streaming workloads with high throughput

For workloads requiring real-time data availability across Regions, this MSK-based solution provides lower latency than the S3-based approach while maintaining the same operational simplicity during impairment scenarios.


## Testing the Active-Active Configuration

To validate the bidirectional replication, we use AWS Lambda functions to produce test messages to both MSK clusters. This serverless approach eliminates the need for EC2 instances while providing the same testing capability.

### Step 1: Create Lambda Layer with Kafka Dependencies

First, create a Lambda layer containing the kafka-python and MSK IAM authentication libraries:

```powershell
# Create layer directory and install dependencies
New-Item -ItemType Directory -Path "lambda-layer/python" -Force
pip install kafka-python aws-msk-iam-sasl-signer-python -t lambda-layer/python

# Create zip file
Compress-Archive -Path "lambda-layer/python" -DestinationPath "kafka-layer.zip" -Force

# Publish layer to both regions
aws lambda publish-layer-version `
    --layer-name kafka-msk-layer `
    --description "Kafka Python client with MSK IAM authentication" `
    --zip-file fileb://kafka-layer.zip `
    --compatible-runtimes python3.11 python3.12 `
    --region us-east-1

aws lambda publish-layer-version `
    --layer-name kafka-msk-layer `
    --description "Kafka Python client with MSK IAM authentication" `
    --zip-file fileb://kafka-layer.zip `
    --compatible-runtimes python3.11 python3.12 `
    --region us-west-2
```

### Step 2: Create IAM Role for Lambda

```powershell
# Create trust policy
$trustPolicy = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
$trustPolicy | Out-File -FilePath "lambda-trust.json" -Encoding ascii -NoNewline

aws iam create-role --role-name msk-test-producer-lambda-role --assume-role-policy-document file://lambda-trust.json

# Attach VPC execution role
aws iam attach-role-policy --role-name msk-test-producer-lambda-role `
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

# Create and attach MSK access policy
$mskPolicy = @'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kafka-cluster:Connect",
                "kafka-cluster:DescribeCluster",
                "kafka-cluster:WriteData",
                "kafka-cluster:DescribeTopic",
                "kafka-cluster:CreateTopic"
            ],
            "Resource": [
                "arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/*",
                "arn:aws:kafka:us-east-1:ACCOUNT_ID:topic/production-msk-primary/*",
                "arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/*",
                "arn:aws:kafka:us-west-2:ACCOUNT_ID:topic/production-msk-secondary/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": ["kafka:GetBootstrapBrokers", "kafka:DescribeCluster"],
            "Resource": "*"
        }
    ]
}
'@
$mskPolicy | Out-File -FilePath "msk-policy.json" -Encoding ascii -NoNewline
aws iam put-role-policy --role-name msk-test-producer-lambda-role --policy-name MSKAccess --policy-document file://msk-policy.json
```

### Step 3: Create Lambda Function Code

Create `msk_producer.py`:

```python
"""
MSK Test Producer Lambda Function
Produces test messages to MSK cluster for validating cross-region replication
"""
import json
import os
import random
from datetime import datetime
from kafka import KafkaProducer
from kafka.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
import boto3


class MSKTokenProvider(AbstractTokenProvider):
    """Token provider for MSK IAM authentication"""
    def __init__(self, region):
        self.region = region
    
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(self.region)
        return token


def get_bootstrap_servers(cluster_arn, region):
    """Get bootstrap servers from MSK cluster ARN"""
    kafka_client = boto3.client('kafka', region_name=region)
    response = kafka_client.get_bootstrap_brokers(ClusterArn=cluster_arn)
    return response.get('BootstrapBrokerStringSaslIam', '')


def produce_messages(bootstrap_servers, topic, count, region, test_id):
    """Produce test messages to MSK topic"""
    producer = KafkaProducer(
        bootstrap_servers=bootstrap_servers.split(','),
        security_protocol='SASL_SSL',
        sasl_mechanism='OAUTHBEARER',
        sasl_oauth_token_provider=MSKTokenProvider(region),
        value_serializer=lambda v: json.dumps(v).encode('utf-8'),
        request_timeout_ms=30000
    )
    
    services = ['api-gateway', 'auth-service', 'user-service', 'payment-service']
    levels = ['INFO', 'WARN', 'ERROR']
    
    messages_sent = []
    for i in range(count):
        msg = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'level': random.choice(levels),
            'service': random.choice(services),
            'message': f'Test message {i+1} from {region}',
            'request_id': f'req-{random.randint(100000, 999999)}',
            'source_region': region,
            'test_id': test_id
        }
        producer.send(topic, value=msg)
        messages_sent.append(msg)
    
    producer.flush()
    producer.close()
    return messages_sent


def handler(event, context):
    """Lambda handler for MSK test producer"""
    cluster_arn = event.get('cluster_arn', os.environ.get('MSK_CLUSTER_ARN'))
    topic = event.get('topic', os.environ.get('KAFKA_TOPIC', 'opensearch-data'))
    count = int(event.get('count', 20))
    test_id = event.get('test_id', f'lambda-test-{datetime.utcnow().strftime("%Y%m%d-%H%M%S")}')
    
    region = cluster_arn.split(':')[3]
    
    result = {'cluster_arn': cluster_arn, 'topic': topic, 'region': region, 'test_id': test_id}
    
    try:
        bootstrap_servers = get_bootstrap_servers(cluster_arn, region)
        messages = produce_messages(bootstrap_servers, topic, count, region, test_id)
        result['status'] = 'SUCCESS'
        result['messages_sent'] = len(messages)
        result['message'] = f'Successfully sent {len(messages)} messages to {topic} in {region}'
    except Exception as e:
        result['status'] = 'FAILED'
        result['error'] = str(e)
    
    return {'statusCode': 200 if result['status'] == 'SUCCESS' else 500, 'body': result}
```

### Step 4: Deploy Lambda Functions

```powershell
# Package Lambda function
Compress-Archive -Path "msk_producer.py" -DestinationPath "msk-producer-lambda.zip" -Force

# Deploy to Primary Region (us-east-1)
aws lambda create-function `
    --function-name msk-test-producer `
    --runtime python3.12 `
    --role arn:aws:iam::ACCOUNT_ID:role/msk-test-producer-lambda-role `
    --handler msk_producer.handler `
    --zip-file fileb://msk-producer-lambda.zip `
    --timeout 120 `
    --memory-size 256 `
    --layers arn:aws:lambda:us-east-1:ACCOUNT_ID:layer:kafka-msk-layer:1 `
    --vpc-config SubnetIds=PRIVATE_SUBNET_1,PRIVATE_SUBNET_2,PRIVATE_SUBNET_3,SecurityGroupIds=MSK_SECURITY_GROUP_ID `
    --environment "Variables={MSK_CLUSTER_ARN=arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/CLUSTER_ID,KAFKA_TOPIC=opensearch-data}" `
    --region us-east-1

# Deploy to Secondary Region (us-west-2)
aws lambda create-function `
    --function-name msk-test-producer `
    --runtime python3.12 `
    --role arn:aws:iam::ACCOUNT_ID:role/msk-test-producer-lambda-role `
    --handler msk_producer.handler `
    --zip-file fileb://msk-producer-lambda.zip `
    --timeout 120 `
    --memory-size 256 `
    --layers arn:aws:lambda:us-west-2:ACCOUNT_ID:layer:kafka-msk-layer:1 `
    --vpc-config SubnetIds=PRIVATE_SUBNET_1,PRIVATE_SUBNET_2,PRIVATE_SUBNET_3,SecurityGroupIds=MSK_SECURITY_GROUP_ID `
    --environment "Variables={MSK_CLUSTER_ARN=arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/CLUSTER_ID,KAFKA_TOPIC=opensearch-data}" `
    --region us-west-2
```

### Step 5: Run Tests

**Test Primary Region (us-east-1):**
```powershell
# Create test payload
@'
{"cluster_arn":"arn:aws:kafka:us-east-1:ACCOUNT_ID:cluster/production-msk-primary/CLUSTER_ID","topic":"opensearch-data","count":20,"test_id":"lambda-primary-test"}
'@ | Set-Content -Path "lambda-payload.json" -NoNewline

# Invoke Lambda
aws lambda invoke `
    --function-name msk-test-producer `
    --cli-binary-format raw-in-base64-out `
    --payload file://lambda-payload.json `
    --region us-east-1 `
    response.json

# Check response
Get-Content response.json | ConvertFrom-Json | ConvertTo-Json -Depth 5
```

**Test Secondary Region (us-west-2):**
```powershell
# Create test payload for secondary
@'
{"cluster_arn":"arn:aws:kafka:us-west-2:ACCOUNT_ID:cluster/production-msk-secondary/CLUSTER_ID","topic":"opensearch-data","count":20,"test_id":"lambda-secondary-test"}
'@ | Set-Content -Path "lambda-payload-secondary.json" -NoNewline

# Invoke Lambda
aws lambda invoke `
    --function-name msk-test-producer `
    --cli-binary-format raw-in-base64-out `
    --payload file://lambda-payload-secondary.json `
    --region us-west-2 `
    response-secondary.json

# Check response
Get-Content response-secondary.json | ConvertFrom-Json | ConvertTo-Json -Depth 5
```

### Step 6: Verify in OpenSearch

After running tests in both regions, verify data in OpenSearch Dashboards:

**Primary OpenSearch Dashboard:**
```
https://COLLECTION_ID.us-east-1.aoss.amazonaws.com/_dashboards
```

**Secondary OpenSearch Dashboard:**
```
https://COLLECTION_ID.us-west-2.aoss.amazonaws.com/_dashboards
```

Run this query in Dev Tools:
```json
GET application-logs-*/_search
{
  "query": { "match_all": {} },
  "size": 50,
  "sort": [{ "timestamp": "desc" }]
}
```

**Expected Results:**
- Both OpenSearch collections should contain messages from BOTH regions
- Look for `source_region` field to identify message origin
- Primary collection: messages from us-east-1 (direct) + us-west-2 (replicated)
- Secondary collection: messages from us-west-2 (direct) + us-east-1 (replicated)

### Step 7: Cleanup Test Resources

```powershell
# Delete Lambda functions
aws lambda delete-function --function-name msk-test-producer --region us-east-1
aws lambda delete-function --function-name msk-test-producer --region us-west-2

# Delete Lambda layers
aws lambda delete-layer-version --layer-name kafka-msk-layer --version-number 1 --region us-east-1
aws lambda delete-layer-version --layer-name kafka-msk-layer --version-number 1 --region us-west-2

# Delete IAM role and policies
aws iam delete-role-policy --role-name msk-test-producer-lambda-role --policy-name MSKAccess
aws iam detach-role-policy --role-name msk-test-producer-lambda-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
aws iam delete-role --role-name msk-test-producer-lambda-role
```

### Important Notes

1. **VPC Configuration**: Lambda functions must be deployed in the same VPC and private subnets as MSK to access the brokers.

2. **Lambda Layer**: The kafka-python and aws-msk-iam-sasl-signer libraries are packaged as a Lambda layer (~17MB) for reuse across functions.

3. **Token Provider**: The `MSKTokenProvider` class must inherit from `AbstractTokenProvider` for kafka-python compatibility with IAM authentication.

4. **Timeout**: Set Lambda timeout to at least 120 seconds to allow for Kafka connection establishment and message production.

5. **Replication Delay**: Allow 30-60 seconds for MSK Replicator to sync data between regions before verifying in OpenSearch.
