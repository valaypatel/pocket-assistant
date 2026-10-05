output "function_url" {
  description = "Paste into Settings, Music recognition, in the app."
  value       = trimsuffix(aws_lambda_function_url.music.function_url, "/")
}

output "service_key" {
  description = "Read with: terraform output -raw service_key"
  value       = random_password.service_key.result
  sensitive   = true
}

output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN variable in the GitHub repository."
  value       = one(aws_iam_role.deploy[*].arn)
}
