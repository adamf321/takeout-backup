resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Belt-and-braces: alarm on the ECS task itself failing to even start/run
# (e.g. bad image, can't pull, crashes before the script's own SNS call
# fires). Catches failures the script can't self-report.
resource "aws_cloudwatch_log_metric_filter" "task_error" {
  name           = "${var.project_name}-error-lines"
  log_group_name = aws_cloudwatch_log_group.backup.name
  pattern        = "\"BACKUP_FAILED\""

  metric_transformation {
    name      = "BackupFailures"
    namespace = "${var.project_name}"
    value     = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "task_error" {
  alarm_name          = "${var.project_name}-failure-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "BackupFailures"
  namespace           = "${var.project_name}"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  alarm_description   = "Fires if the backup runner logs a BACKUP_FAILED line"
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
