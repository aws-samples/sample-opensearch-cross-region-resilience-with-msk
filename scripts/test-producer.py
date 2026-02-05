#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# DISCLAIMER: This code is provided as a reference implementation and is not
# intended for production use without thorough review and customization.

"""
Test data producer for OpenSearch MSK integration
Produces sample log data to MSK topic for testing cross-region replication
"""

import json
import time
import argparse
import random
import sys
from datetime import datetime
from typing import Dict, List

try:
    from kafka import KafkaProducer
    from kafka.errors import KafkaError
    from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
except ImportError:
    print("Error: Required packages not installed.")
    print("Please install: pip install kafka-python aws-msk-iam-sasl-signer-python")
    sys.exit(1)


class TestDataProducer:
    """Producer class for generating and sending test data to MSK"""
    
    def __init__(self, bootstrap_servers: str, topic: str, region: str):
        self.bootstrap_servers = bootstrap_servers
        self.topic = topic
        self.region = region
        self.producer = None
        
        # Sample data for generating realistic log entries
        self.services = ['api-gateway', 'auth-service', 'user-service', 'payment-service', 'notification-service']
        self.log_levels = ['INFO', 'WARN', 'ERROR', 'DEBUG']
        self.log_level_weights = [0.7, 0.15, 0.1, 0.05]  # Distribution of log levels
        self.message_templates = [
            'Request processed successfully',
            'User authentication completed',
            'Database query executed',
            'Cache hit for key',
            'API endpoint called',
            'Transaction completed',
            'Validation passed',
            'Data synchronization finished',
            'Background job started',
            'Health check passed'
        ]
        
    def _create_producer(self) -> KafkaProducer:
        """Create and configure Kafka producer with IAM authentication"""
        
        def token_provider():
            """Provide MSK IAM auth token"""
            token, _ = MSKAuthTokenProvider.generate_auth_token(self.region)
            return token
        
        try:
            producer = KafkaProducer(
                bootstrap_servers=self.bootstrap_servers.split(','),
                security_protocol='SASL_SSL',
                sasl_mechanism='OAUTHBEARER',
                sasl_oauth_token_provider=token_provider,
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                key_serializer=lambda k: k.encode('utf-8') if k else None,
                acks='all',
                retries=3,
                max_in_flight_requests_per_connection=5,
                compression_type='snappy',
                linger_ms=10,
                batch_size=16384
            )
            print(f"✓ Successfully connected to MSK cluster at {self.bootstrap_servers}")
            return producer
        except KafkaError as e:
            print(f"✗ Failed to create Kafka producer: {e}")
            sys.exit(1)
    
    def generate_log_entry(self, index: int) -> Dict:
        """Generate a realistic log entry"""
        service = random.choice(self.services)
        log_level = random.choices(self.log_levels, weights=self.log_level_weights)[0]
        message = random.choice(self.message_templates)
        
        return {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'level': log_level,
            'service': service,
            'message': f'{message} - ID:{index}',
            'request_id': f'req-{random.randint(100000, 999999)}',
            'user_id': f'user-{random.randint(1, 1000)}',
            'duration_ms': random.randint(10, 500),
            'status_code': random.choice([200, 200, 200, 201, 400, 404, 500]),
            'environment': 'production',
            'region': self.region
        }
    
    def produce_messages(self, count: int, delay_ms: int = 0, batch_size: int = 100):
        """Produce messages to Kafka topic"""
        
        if not self.producer:
            self.producer = self._create_producer()
        
        print(f"\n📤 Starting to produce {count} messages to topic '{self.topic}'...")
        print(f"   Delay between batches: {delay_ms}ms")
        print(f"   Batch size: {batch_size}")
        print("-" * 70)
        
        successful = 0
        failed = 0
        start_time = time.time()
        
        try:
            for i in range(count):
                log_entry = self.generate_log_entry(i + 1)
                
                # Use service name as partition key for better distribution
                partition_key = log_entry['service']
                
                # Send message asynchronously
                future = self.producer.send(
                    self.topic,
                    key=partition_key,
                    value=log_entry
                )
                
                # Add callback for delivery confirmation
                future.add_callback(lambda metadata: None)
                future.add_errback(lambda e: print(f"✗ Message {i+1} failed: {e}"))
                
                successful += 1
                
                # Progress indicator
                if (i + 1) % batch_size == 0:
                    self.producer.flush()
                    elapsed = time.time() - start_time
                    rate = (i + 1) / elapsed
                    print(f"✓ Produced {i + 1}/{count} messages ({rate:.1f} msg/s)")
                    
                    if delay_ms > 0 and (i + 1) < count:
                        time.sleep(delay_ms / 1000)
            
            # Final flush
            self.producer.flush()
            
        except KeyboardInterrupt:
            print("\n\n⚠ Interrupted by user")
            self.producer.flush()
        except Exception as e:
            print(f"\n✗ Error during production: {e}")
            failed += 1
        
        # Summary
        elapsed = time.time() - start_time
        print("-" * 70)
        print(f"\n📊 Production Summary:")
        print(f"   Total messages: {count}")
        print(f"   Successful: {successful}")
        print(f"   Failed: {failed}")
        print(f"   Duration: {elapsed:.2f}s")
        print(f"   Average rate: {successful / elapsed:.1f} msg/s")
        print(f"   Topic: {self.topic}")
        print(f"   Partition strategy: Key-based (by service)")
    
    def close(self):
        """Close the producer connection"""
        if self.producer:
            self.producer.close()
            print("\n✓ Producer connection closed")


def main():
    """Main function to parse arguments and run the producer"""
    
    parser = argparse.ArgumentParser(
        description='Test data producer for OpenSearch MSK integration',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Produce 1000 messages
  python test-producer.py --bootstrap-servers b-1.msk.us-east-1.amazonaws.com:9098 --count 1000
  
  # Produce messages with delay between batches
  python test-producer.py --bootstrap-servers $MSK_BOOTSTRAP --count 5000 --delay 100
  
  # Produce to custom topic
  python test-producer.py --bootstrap-servers $MSK_BOOTSTRAP --topic my-topic --count 10000
        """
    )
    
    parser.add_argument(
        '--bootstrap-servers',
        required=True,
        help='MSK bootstrap servers (comma-separated)'
    )
    
    parser.add_argument(
        '--topic',
        default='opensearch-data',
        help='Kafka topic name (default: opensearch-data)'
    )
    
    parser.add_argument(
        '--region',
        default='us-east-1',
        help='AWS region (default: us-east-1)'
    )
    
    parser.add_argument(
        '--count',
        type=int,
        default=1000,
        help='Number of messages to produce (default: 1000)'
    )
    
    parser.add_argument(
        '--delay',
        type=int,
        default=0,
        help='Delay in milliseconds between batches (default: 0)'
    )
    
    parser.add_argument(
        '--batch-size',
        type=int,
        default=100,
        help='Number of messages per batch for progress reporting (default: 100)'
    )
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.count <= 0:
        print("Error: count must be greater than 0")
        sys.exit(1)
    
    if args.delay < 0:
        print("Error: delay cannot be negative")
        sys.exit(1)
    
    # Create producer and start producing
    print("=" * 70)
    print("  OpenSearch MSK Test Data Producer")
    print("=" * 70)
    
    producer = TestDataProducer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        region=args.region
    )
    
    try:
        producer.produce_messages(
            count=args.count,
            delay_ms=args.delay,
            batch_size=args.batch_size
        )
    finally:
        producer.close()
    
    print("\n✅ Done!\n")


if __name__ == '__main__':
    main()
