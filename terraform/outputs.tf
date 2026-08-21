output "summary" {
  value = <<-EOT

    Deployed:
      ECS cluster:        ${aws_ecs_cluster.backup.name}
      ECR repo:            ${aws_ecr_repository.backup.repository_url}
      S3 bucket:            ${aws_s3_bucket.backups.bucket}
      Secrets Manager ARN:  ${aws_secretsmanager_secret.google_oauth.arn}
      SNS topic:             ${aws_sns_topic.alerts.arn}
      Schedule:               ${var.schedule_expression} (UTC)

    Next steps (see README.md):
      1. Confirm the SNS email subscription (check your inbox).
      2. Build & push the container image to the ECR repo above.
      3. Generate google-oauth.json and put it into the secret.
      4. (Optional) Run the ECS task once manually to test before waiting
         for the schedule.
  EOT
}
