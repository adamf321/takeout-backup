resource "aws_scheduler_schedule" "backup_run" {
  name       = "${var.project_name}-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_ecs_cluster.backup.arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.backup.arn
      launch_type         = "FARGATE"

      network_configuration {
        subnets          = data.aws_subnets.default_public.ids
        security_groups  = [aws_security_group.backup_task.id]
        assign_public_ip = true
      }
    }

    retry_policy {
      maximum_retry_attempts       = 1
      maximum_event_age_in_seconds = 3600
    }
  }
}
