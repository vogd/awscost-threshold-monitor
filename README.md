# Cost Threshold Monitor

Serverless cost alerting that queries CUDOS/CID Athena data, compares against configurable thresholds, and sends email alerts via SES.

## Architecture

```
EventBridge (rate 1 hour) → Lambda → Athena (cur2) → SES email
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

This solution requires CUDOS (or CID) to be deployed in your account, which provides the `cur2` Athena table used for cost queries. CUDOS setup includes:

1. **CUR 2.0 data export** — configured in AWS Billing console with:
   - Hourly granularity enabled
   - Resource IDs included
   - `resource_tags` and `cost_category` columns selected (Column selection → 127/127)
   - Export to S3 bucket (e.g. `cid-<account_id>-<your-bucket-name>`)
2. **Cost allocation tags** — activated in Billing console (e.g. `env`, `project`)
3. **Athena workgroup** — typically named `CID`, with a results S3 bucket
4. **Glue database and table** — database (e.g. `customer_cur_data`) with `cur2` table containing hourly line items, resource ARNs, and `resource_tags` MAP column
5. **Glue crawler** — to keep table schema in sync with CUR data

Deploy CUDOS using the official workshop: https://catalog.workshops.aws/awscid/en-US

### Other prerequisites

- AWS CLI configured with sufficient permissions
- Terraform >= 1.0
- SES sender email you can verify (check inbox for AWS verification link)

## Project structure

```
cost-monitor/
├── LICENSE
├── README.md
└── terraform/
    ├── main.tf                # All resources (IAM, Lambda, EventBridge, SES)
    ├── variables.tf           # Configurable parameters
    ├── outputs.tf             # ARNs, bucket names, helper commands
    ├── terraform.tfvars       # Your values (gitignored)
    ├── lambda_function.py.tpl # Lambda source template
    └── .gitignore
```

## Deploy

Find your CUR 2.0 data export details first:

```bash
# List data exports to find your export name and S3 bucket
aws bcm-data-exports list-exports --region us-east-1 --query 'Exports[].ExportArn' --output text

# Get bucket and export name from the ARN
aws bcm-data-exports get-export \
  --export-arn "<your-export-arn>" \
  --region us-east-1 \
  --query 'Export.{Name:Name,Bucket:DestinationConfigurations.S3Destination.S3Bucket}' \
  --output table
```

Then configure and deploy:

```bash
cd cost-monitor/terraform

# Set required parameters (use values from above)
cat > terraform.tfvars <<EOF
ses_sender        = "your-email@gmail.com"
region            = "us-east-1"
athena_workgroup  = "CID"
database          = "customer_cur_data"
cid_data_bucket   = "cid-<account_id>-<your-bucket-name>"
data_export_name  = "<yourCUR-export-name>"
EOF

# Deploy
terraform init
terraform apply

# Verify SES — click the link in the verification email sent to your address
```

## Override defaults

Optional parameters can be overridden on the command line:

```bash
terraform apply \
  -var='schedule=rate(6 hours)' \
  -var='top_services=10' \
  -var='top_resources=20'
```

Required parameters should be set in `terraform.tfvars` (see Deploy section above).

All variables (see `variables.tf`):

**Required — must match your CUDOS deployment:**

| Variable | Source | Description |
|---|---|---|
| `ses_sender` | User-provided | From address for alerts (must be SES-verified) |
| `region` | CUDOS region | AWS region where CUDOS is deployed |
| `athena_workgroup` | CUDOS setup | Athena workgroup (e.g. `CID`) |
| `database` | CUDOS setup | Athena database (e.g. `customer_cur_data`) |
| `cid_data_bucket` | Data Exports | S3 bucket where CUR data exports are stored |
| `data_export_name` | Data Exports | CUR 2.0 data export name (S3 path: `s3://<bucket>/cur2/<data_export_name>/data/`) |

**Auto-derived (no input needed):**

| Value | Source |
|---|---|
| `account_id` | `aws_caller_identity` data source |
| `athena_results_bucket` | Read from Athena workgroup configuration |

**Optional — Lambda configuration with sensible defaults:**

| Variable | Default | Description |
|---|---|---|
| `profile` | `null` | AWS CLI profile name |
| `function_name` | `cost-threshold-monitor` | Lambda name |
| `role_name` | `cost-monitor-lambda-role` | IAM role name |
| `schedule` | `rate(1 hour)` | EventBridge schedule |
| `lambda_timeout` | `300` | Lambda timeout (seconds) |
| `lambda_memory` | `128` | Lambda memory (MB) |
| `top_services` | `5` | Top N services in alert |
| `top_resources` | `10` | Top N resource ARNs in alert |

## Configure thresholds (SSM Parameters)

Thresholds are stored in SSM under `/cost/thresholds/<tag_key>/<tag_value>`.

The `<tag_key>` in the SSM path uses the `tag_` prefix convention. The Lambda strips this prefix and maps it to the CUR 2.0 `resource_tags` MAP column as `user_<tag>`:

| SSM path | CUR 2.0 filter |
|---|---|
| `/cost/thresholds/tag_env/prod` | `resource_tags['user_env'] = 'prod'` |
| `/cost/thresholds/tag_project/ml` | `resource_tags['user_project'] = 'ml'` |

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
# Alert when env=prod exceeds $100/day or $2000/month
aws ssm put-parameter \
  --name '/cost/thresholds/tag_env/prod' \
  --value '{"daily":{"threshold":100,"recipients":["team@example.com"]},"monthly":{"threshold":2000,"recipients":["finops@example.com"]}}' \
  --type String --region us-east-1

# Alert when env=dev exceeds $20/day or $500/month
aws ssm put-parameter \
  --name '/cost/thresholds/tag_env/dev' \
  --value '{"daily":{"threshold":20,"recipients":["dev-lead@example.com"]},"monthly":{"threshold":500,"recipients":["dev-lead@example.com"]}}' \
  --type String --region us-east-1

# Alert for a specific project tag
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
