variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "takeout-backup"
}

variable "backup_bucket_name" {
  description = "Globally-unique S3 bucket name for the backups"
  type        = string
  # No default on purpose — bucket names are global, pick something unique.
  # e.g. "adam-google-takeout-backups-2026"
}

variable "alert_email" {
  description = "Email address to notify on backup success/failure"
  type        = string
}

variable "glacier_transition_days" {
  description = "Days after upload before objects move to Glacier Deep Archive"
  type        = number
  default     = 30
}

variable "backup_retention_years" {
  description = "How many years to keep backups before expiring them. Set to 0 to keep forever."
  type        = number
  default     = 0
}

variable "container_image_tag" {
  description = "Tag of the image in ECR to run (set after your first docker push)"
  type        = string
  default     = "latest"
}

variable "schedule_expression" {
  description = <<-EOT
    EventBridge Scheduler cron expression, UTC. Default fires the 21st of
    every month at 06:00 UTC — adjust the day to trail a few days behind
    whatever date your Takeout export actually lands on Drive.
  EOT
  type    = string
  default = "cron(0 6 21 * ? *)"
}

variable "task_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU)"
  type        = string
  default     = "1024"
}

variable "task_memory" {
  description = "Fargate task memory in MB"
  type        = string
  default     = "3072"
}

variable "task_timeout_hours" {
  description = "Hard ceiling on how long a single backup run is allowed to take, as a safety net (not a Lambda-style limit — Fargate has none — just a guardrail against a runaway task)"
  type        = number
  default     = 6
}
