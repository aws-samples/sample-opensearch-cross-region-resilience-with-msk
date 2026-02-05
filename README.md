# Cross-Region Active-Active OpenSearch with Amazon MSK

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![AWS](https://img.shields.io/badge/AWS-CloudFormation-orange)](https://aws.amazon.com/cloudformation/)

A serverless, active-active cross-region architecture for Amazon OpenSearch using MSK Replicator and OpenSearch Ingestion (OSI).

## Architecture

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────────┐
│         PRIMARY (us-east-1)         │     │        SECONDARY (us-west-2)        │
│                                     │     │                                     │
│  ┌─────────┐    ┌───────────────┐   │     │   ┌───────────────┐    ┌─────────┐  │
│  │ Lambda  │───▶│  MSK Cluster  │◀──┼─────┼──▶│  MSK Cluster  │◀───│ Lambda  │  │
│  └─────────┘    └───────┬───────┘   │     │   └───────┬───────┘    └─────────┘  │
│                         │           │     │           │                         │
│                         ▼           │     │           ▼                         │
│                 ┌───────────────┐   │     │   ┌───────────────┐                 │
│                 │ OSI Pipeline  │   │     │   │ OSI Pipeline  │                 │
│                 └───────┬───────┘   │     │   └───────┬───────┘                 │
│                         │           │     │           │                         │
│                         ▼           │     │           ▼                         │
│                 ┌───────────────┐   │     │   ┌───────────────┐                 │
│                 │  OpenSearch   │   │     │   │  OpenSearch   │                 │
│                 │  Serverless   │   │     │   │  Serverless   │                 │
│                 └───────────────┘   │     │   └───────────────┘                 │
└─────────────────────────────────────┘     └─────────────────────────────────────┘
                    ◀───── MSK Replicator (Bidirectional) ─────▶
```

## Features

- **Active-Active Replication** - Both regions process data simultaneously
- **Near Real-Time Sync** - MSK Replicator provides sub-second replication
- **Producers** - Lambda function for testing
- **Automatic Failover** - No manual reconfiguration during failback
- **IDENTICAL Topic Naming** - Same topic names in both regions with loop prevention

## Quick Start

```powershell
# 1. Deploy VPC infrastructure
aws cloudformation create-stack --stack-name production-vpc-primary `
  --template-body file://cloudformation/vpc-infrastructure.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
  --region us-east-1 --capabilities CAPABILITY_NAMED_IAM

# 2. Deploy primary region
aws cloudformation create-stack --stack-name production-opensearch-primary `
  --template-body file://cloudformation/primary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
  --region us-east-1 --capabilities CAPABILITY_NAMED_IAM

# 3. Deploy secondary region (after primary completes)
aws cloudformation create-stack --stack-name production-opensearch-secondary `
  --template-body file://cloudformation/secondary-region.yaml `
  --parameters ParameterKey=EnvironmentName,ParameterValue=production `
    ParameterKey=PrimaryMSKClusterArn,ParameterValue=<PRIMARY_MSK_ARN> `
  --region us-west-2 --capabilities CAPABILITY_NAMED_IAM
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for complete instructions.

## Repository Structure

```
├── cloudformation/              # CloudFormation templates
│   ├── primary-region.yaml      # Primary region (MSK, OSI, OpenSearch)
│   ├── secondary-region.yaml    # Secondary region + MSK Replicator
│   ├── vpc-infrastructure.yaml  # VPC with private subnets
│   └── test-lambda.yaml         # Lambda test producer template
├── scripts/
│   ├── lambda/
│   │   └── msk_producer.py      # Lambda test producer code
│   ├── deploy-all.ps1           # Automated deployment
│   ├── cleanup-all-resources.ps1
│   └── validate-replication.ps1
├── docs/
│   ├── deployment-guide.md      # Step-by-step deployment
│   ├── disaster-recovery-testing.md
│   └── architecture-overview.md
├── architecture/
│   └── architecture-diagram.md
├── MSK-Blog-Specific.md         # Complete blog post
├── CLEANUP-GUIDE.md             # Resource cleanup instructions
└── requirements.txt             # Python dependencies
```

## Testing

Deploy Lambda test producers and send messages to both regions:

```powershell
# Test Primary Region
aws lambda invoke --function-name msk-test-producer --region us-east-1 `
  --cli-binary-format raw-in-base64-out --payload '{"count":20}' response.json

# Test Secondary Region  
aws lambda invoke --function-name msk-test-producer --region us-west-2 `
  --cli-binary-format raw-in-base64-out --payload '{"count":20}' response.json
```

Both OpenSearch collections will contain messages from both regions.

## Deployment Time

| Resource | Time |
|----------|------|
| VPC Infrastructure | ~10 min |
| MSK Cluster | 25-35 min |
| Multi-VPC Connectivity | 15-25 min |
| OSI Pipeline | 5-10 min |
| MSK Replicator | 15-30 min |
| **Total** | **~2.5-3.5 hours** |

## Documentation

- [Deployment Guide](docs/deployment-guide.md) - Step-by-step deployment
- [MSK Blog Post](MSK-Blog-Specific.md) - Detailed architecture and configuration
- [DR Testing](docs/disaster-recovery-testing.md) - Failover/failback procedures
- [Cleanup Guide](CLEANUP-GUIDE.md) - Resource deletion

## Prerequisites

- AWS CLI v2.x configured with appropriate permissions
- PowerShell (Windows) or Bash (Linux/Mac)
- Two AWS regions (default: us-east-1, us-west-2)

## Cost Considerations

This solution incurs costs for:
- Amazon MSK clusters (both regions)
- MSK Replicator (cross-region data transfer)
- OpenSearch Serverless collections
- OpenSearch Ingestion pipelines
- Lambda executions (minimal for testing)

## Security

### Principle of Least Privilege

IAM roles in this solution are configured with permissions scoped to specific resources. Review and customize IAM policies based on your organization's security requirements.

- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Grant Least Privilege](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#grant-least-privilege)
- [IAM Policy Evaluation Logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)

### OpenSearch Domain Security

OpenSearch Serverless collections use encryption, network policies, and data access policies.

- [OpenSearch Serverless Security](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-security.html)
- [Data Access Control for OpenSearch Serverless](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-data-access.html)
- [Network Access for OpenSearch Serverless](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/serverless-network.html)

### Amazon MSK Security

MSK clusters use IAM authentication, encryption in transit (TLS), and encryption at rest (KMS).

- [Amazon MSK Security](https://docs.aws.amazon.com/msk/latest/developerguide/security.html)
- [MSK IAM Access Control](https://docs.aws.amazon.com/msk/latest/developerguide/iam-access-control.html)
- [MSK Encryption](https://docs.aws.amazon.com/msk/latest/developerguide/msk-encryption.html)

### Security Considerations

This solution provides a reference architecture. Before deploying to production:

- Review and customize IAM policies to match your least-privilege requirements
- Enable VPC Flow Logs for network traffic monitoring
- Configure CloudWatch alarms for security-related metrics
- Implement additional network controls (NACLs, security group rules) as needed
- Enable AWS CloudTrail for API activity logging
- Consider enabling AWS Config rules for compliance monitoring
- Review KMS key policies and rotation settings
- Conduct a security review specific to your use case and compliance requirements

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Authors and Acknowledgment

- Qais Poonawala - qppoonaw@amazon.com
- Sriharsha Subramanya Begolli - begollis@amazon.com
- Jay Jothi - jayjothe@amazon.com

## License

[MIT License](LICENSE)

## Resources

- [Amazon OpenSearch Service](https://docs.aws.amazon.com/opensearch-service/)
- [Amazon MSK](https://docs.aws.amazon.com/msk/)
- [OpenSearch Ingestion](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ingestion.html)
- [MSK Replicator](https://docs.aws.amazon.com/msk/latest/developerguide/msk-replicator.html)
