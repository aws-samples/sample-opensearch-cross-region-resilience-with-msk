# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# DISCLAIMER: This code is provided as a reference implementation and is not
# intended for production use without thorough review and customization.
# Review IAM policies and security configurations to ensure they meet your
# organization's security requirements.

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
        request_timeout_ms=30000,
        api_version_auto_timeout_ms=30000
    )
    
    services = ['api-gateway', 'auth-service', 'user-service', 'payment-service', 'notification-service']
    levels = ['INFO', 'WARN', 'ERROR']
    level_weights = [0.7, 0.2, 0.1]
    
    messages_sent = []
    for i in range(count):
        msg = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'level': random.choices(levels, weights=level_weights)[0],
            'service': random.choice(services),
            'message': f'Test message {i+1} from {region}',
            'request_id': f'req-{random.randint(100000, 999999)}',
            'user_id': f'user-{random.randint(1, 1000)}',
            'duration_ms': random.randint(10, 500),
            'status_code': random.choice([200, 200, 200, 201, 400, 404, 500]),
            'source_region': region,
            'test_id': test_id,
            'test_timestamp': datetime.utcnow().isoformat()
        }
        producer.send(topic, value=msg)
        messages_sent.append(msg)
    
    producer.flush()
    producer.close()
    
    return messages_sent


def handler(event, context):
    """
    Lambda handler for MSK test producer
    
    Event parameters:
    - cluster_arn: MSK cluster ARN (optional, uses env var if not provided)
    - topic: Kafka topic name (default: opensearch-data)
    - count: Number of messages to produce (default: 20)
    - test_id: Identifier for this test run (default: auto-generated)
    """
    
    # Get parameters
    cluster_arn = event.get('cluster_arn', os.environ.get('MSK_CLUSTER_ARN'))
    topic = event.get('topic', os.environ.get('KAFKA_TOPIC', 'opensearch-data'))
    count = int(event.get('count', 20))
    test_id = event.get('test_id', f'lambda-test-{datetime.utcnow().strftime("%Y%m%d-%H%M%S")}')
    
    # Extract region from cluster ARN
    region = cluster_arn.split(':')[3]
    
    result = {
        'cluster_arn': cluster_arn,
        'topic': topic,
        'region': region,
        'requested_count': count,
        'test_id': test_id,
        'steps': []
    }
    
    try:
        # Step 1: Get bootstrap servers
        bootstrap_servers = get_bootstrap_servers(cluster_arn, region)
        result['bootstrap_servers'] = bootstrap_servers
        result['steps'].append({'step': 'get_bootstrap_servers', 'status': 'success'})
        
        # Step 2: Produce messages
        messages = produce_messages(bootstrap_servers, topic, count, region, test_id)
        result['messages_sent'] = len(messages)
        result['sample_message'] = messages[0] if messages else None
        result['steps'].append({'step': 'produce_messages', 'status': 'success', 'count': len(messages)})
        
        result['status'] = 'SUCCESS'
        result['message'] = f'Successfully sent {len(messages)} messages to {topic} in {region}'
        
    except Exception as e:
        result['status'] = 'FAILED'
        result['error'] = str(e)
        result['steps'].append({'step': 'error', 'status': 'failed', 'error': str(e)})
    
    return {
        'statusCode': 200 if result['status'] == 'SUCCESS' else 500,
        'body': result
    }
