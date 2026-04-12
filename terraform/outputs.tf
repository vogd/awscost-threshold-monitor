output "lambda_arn" {
  value = aws_lambda_function.cost_monitor.arn
}

output "role_arn" {
  value = aws_iam_role.lambda.arn
}

output "schedule_rule_arn" {
  value = aws_cloudwatch_event_rule.schedule.arn
}

output "athena_results_bucket" {
  value = local.athena_results_bucket
}

output "cid_data_bucket" {
  value = local.cid_data_bucket
}

output "invoke_command" {
  value = "aws lambda invoke --function-name ${var.function_name} --region ${var.region} --payload '{}' --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json"
}

output "ssm_example" {
  value = "aws ssm put-parameter --name '/cost/thresholds/tag_env/prod' --value '{\"daily\":{\"threshold\":100,\"recipients\":[\"team@example.com\"]},\"monthly\":{\"threshold\":2000,\"recipients\":[\"finops@example.com\"]}}' --type String --region ${var.region}"
}
