terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

# ── Data sources (auto-derive account ID and bucket names) ───────────────────

data "aws_caller_identity" "current" {}

data "external" "athena_workgroup" {
  program = ["bash", "-c", <<-EOF
    PROFILE_ARG=""
    if [ -n "${var.profile != null ? var.profile : ""}" ]; then
      PROFILE_ARG="--profile ${var.profile}"
    fi
    LOCATION=$(aws athena get-work-group \
      --work-group "${var.athena_workgroup}" \
      --region "${var.region}" \
      $PROFILE_ARG \
      --query 'WorkGroup.Configuration.ResultConfiguration.OutputLocation' \
      --output text)
    BUCKET=$(echo "$LOCATION" | sed 's|s3://||' | cut -d'/' -f1)
    echo "{\"bucket\": \"$BUCKET\"}"
  EOF
  ]
}

locals {
  account_id            = data.aws_caller_identity.current.account_id
  athena_results_bucket = data.external.athena_workgroup.result.bucket
  cid_data_bucket       = var.cid_data_bucket
}

# ── SES sender identity ─────────────────────────────────────────────────────

resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.ses_sender
}

# ── IAM role ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = var.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "cost_monitor" {
  name = "cost-monitor-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Athena"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "arn:aws:athena:${var.region}:${local.account_id}:workgroup/${var.athena_workgroup}"
      },
      {
        Sid    = "Glue"
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:${var.region}:${local.account_id}:catalog",
          "arn:aws:glue:${var.region}:${local.account_id}:database/${var.database}",
          "arn:aws:glue:${var.region}:${local.account_id}:table/${var.database}/*"
        ]
      },
      {
        Sid    = "S3Results"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation"]
        Resource = [
          "arn:aws:s3:::${local.athena_results_bucket}",
          "arn:aws:s3:::${local.athena_results_bucket}/*"
        ]
      },
      {
        Sid    = "S3CIDData"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.cid_data_bucket}",
          "arn:aws:s3:::${local.cid_data_bucket}/*"
        ]
      },
      {
        Sid      = "SSM"
        Effect   = "Allow"
        Action   = "ssm:GetParametersByPath"
        Resource = "arn:aws:ssm:${var.region}:${local.account_id}:parameter/cost/*"
      },
      {
        Sid      = "SES"
        Effect   = "Allow"
        Action   = "ses:SendEmail"
        Resource = "arn:aws:ses:${var.region}:${local.account_id}:identity/${var.ses_sender}"
      }
    ]
  })
}

# ── Lambda function ──────────────────────────────────────────────────────────

resource "local_file" "lambda_source" {
  content = templatefile("${path.module}/lambda_function.py.tpl", {
    region        = var.region
    workgroup     = var.athena_workgroup
    database      = var.database
    ses_sender    = var.ses_sender
    top_services  = var.top_services
    top_resources = var.top_resources
  })
  filename = "${path.module}/.build/lambda_function.py"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = local_file.lambda_source.filename
  output_path = "${path.module}/.build/lambda.zip"
}

resource "aws_lambda_function" "cost_monitor" {
  function_name    = var.function_name
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
}

# ── EventBridge schedule ─────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.function_name}-schedule"
  schedule_expression = var.schedule
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.cost_monitor.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "eventbridge-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
