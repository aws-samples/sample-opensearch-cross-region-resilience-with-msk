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

