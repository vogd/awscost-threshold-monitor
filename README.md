# Cost Threshold Monitor

Serverless cost alerting that queries CUDOS/CID Athena data, compares against configurable thresholds, and sends email alerts via SES.

## Architecture

```
EventBridge (rate 1 hour) → Lambda → Athena (summary_view + cur2) → SES email
                                    ↑
                              SSM Parameters (thresholds)
```

## Why CUDOS/CID instead of Cost Explorer API

This solution queries Athena tables populated by [CUDOS](https://catalog.workshops.aws/awscid/en-US) (CUR 2.0 data exports) rather than the AWS Cost Explorer API. Key reasons:

| | Cost Explorer API | CUDOS / Athena (this solution) |
|---|---|---|
| Hourly cost data | ❌ Daily and monthly only | ✅ Hourly line items from CUR 2.0 |
| Resource ARNs | EC2 only, 14-day limit | ✅ All services, full history |
| Tag filtering | Limited to cost allocation tags, max 2 group-by dimensions | ✅ Any tag via SQL, unlimited grouping |
| Query flexibility | Fixed API parameters | Full SQL — joins, subqueries, window functions |
| Cost per query | $0.01 per API call | ~$0.005 per query (data scanned) |
| Historical depth | 12 months | Full CUR history |

The hourly granularity and resource-level ARN detail across all services are capabilities that Cost Explorer simply cannot provide. The tradeoff is that CUDOS must be deployed first.

## Prerequisites

### CUDOS/CID deployment

This solution requires CUDOS (or CID) to be deployed in your account, which provides the Athena tables (`summary_view`, `cur2`) used for cost queries. CUDOS setup includes:

1. **CUR 2.0 data export** — configured in AWS Billing console with:
   - Hourly granularity enabled
   - Resource IDs included
   - Export to S3 bucket (e.g. `cid-<account_id>-data-exports`)
2. **Athena workgroup** — typically named `CID`, with a results S3 bucket
3. **Glue database and tables** — `cid_data_export` database with `summary_view` (aggregated daily costs) and `cur2` (raw hourly line items with resource ARNs)
4. **Glue crawler or CloudFormation** — to keep table schemas in sync with CUR data

Deploy CUDOS using the official workshop: https://catalog.workshops.aws/awscid/en-US

### Other prerequisites

- AWS CLI configured with sufficient permissions
- Terraform >= 1.0
- SES sender email you can verify (check inbox for AWS verification link)

## Project structure

```
cost-monitor/
└── terraform/
    ├── main.tf                # All resources (IAM, Lambda, EventBridge, SES)
    ├── variables.tf           # Configurable parameters
    ├── outputs.tf             # ARNs, bucket names, helper commands
    ├── terraform.tfvars       # Your values
    ├── lambda_function.py.tpl # Lambda source template
    ├── README.md
    └── .gitignore
```

## Deploy

```bash
cd cost-monitor/terraform

# Edit sender email
echo 'ses_sender = "your-email@gmail.com"' > terraform.tfvars

# Deploy
terraform init
terraform apply

# Verify SES — click the link in the verification email sent to your address
```

## Override defaults

```bash
terraform apply \
  -var='ses_sender=alerts@yourdomain.com' \
  -var='schedule=rate(6 hours)' \
  -var='lambda_timeout=300' \
  -var='top_services=10' \
  -var='top_resources=20'
```

All variables (see `variables.tf`):

| Variable | Default | Description |
|---|---|---|
| `ses_sender` | (required) | From address for alerts |
| `region` | `us-east-1` | AWS region |
| `athena_workgroup` | `CID` | Athena workgroup |
| `database` | `cid_data_export` | Athena database |
| `function_name` | `cost-threshold-monitor` | Lambda name |
| `role_name` | `cost-monitor-lambda-role` | IAM role name |
| `schedule` | `rate(1 hour)` | EventBridge schedule |
| `lambda_timeout` | `300` | Lambda timeout (seconds) |
| `lambda_memory` | `128` | Lambda memory (MB) |
| `top_services` | `5` | Top N services in alert |
| `top_resources` | `10` | Top N resource ARNs in alert |

## Configure thresholds (SSM Parameters)

Thresholds are stored in SSM under `/cost/thresholds/<tag_key>/<tag_value>`.

### Format

```json
{
  "daily": {
    "threshold": 100,
    "recipients": ["team@example.com", "manager@example.com"]
  },
  "monthly": {
    "threshold": 2000,
    "recipients": ["finops@example.com"]
  }
}
```

### Examples

```bash
# Alert when tag_env=prod exceeds $100/day or $2000/month
aws ssm put-parameter \
  --name '/cost/thresholds/tag_env/prod' \
  --value '{"daily":{"threshold":100,"recipients":["team@example.com"]},"monthly":{"threshold":2000,"recipients":["finops@example.com"]}}' \
  --type String --region us-east-1

# Alert when tag_env=dev exceeds $20/day
aws ssm put-parameter \
  --name '/cost/thresholds/tag_env/dev' \
  --value '{"daily":{"threshold":20,"recipients":["dev-lead@example.com"]},"monthly":{"threshold":500,"recipients":["dev-lead@example.com"]}}' \
  --type String --region us-east-1

# Alert for a specific project
aws ssm put-parameter \
  --name '/cost/thresholds/tag_project/ml-training' \
  --value '{"daily":{"threshold":500,"recipients":["ml-team@example.com"]},"monthly":{"threshold":10000,"recipients":["ml-team@example.com","finance@example.com"]}}' \
  --type String --region us-east-1
```

### List existing thresholds

```bash
aws ssm get-parameters-by-path --path /cost/thresholds --recursive --region us-east-1 \
  --query 'Parameters[].[Name,Value]' --output table
```

### Delete a threshold

```bash
aws ssm delete-parameter --name '/cost/thresholds/tag_env/dev' --region us-east-1
```

## Test

```bash
aws lambda invoke --function-name cost-threshold-monitor --region us-east-1 \
  --payload '{}' --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json
```

## Destroy

```bash
cd terraform
terraform destroy
```

Note: SSM threshold parameters are not managed by Terraform and will persist after destroy.

## SES Sandbox

If your account is in SES sandbox mode, both sender AND recipient emails must be verified. Request production access in the SES console to send to any recipient.
