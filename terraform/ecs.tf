resource "aws_ecs_cluster" "backup" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # not worth the extra cost for something that runs 6x/year
  }
}

resource "aws_cloudwatch_log_group" "backup" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 90
}

resource "aws_ecs_task_definition" "backup" {
  family                   = "${var.project_name}-runner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "backup-runner"
      image     = "${aws_ecr_repository.backup.repository_url}:${var.container_image_tag}"
      essential = true

      environment = [
        { name = "S3_BUCKET", value = aws_s3_bucket.backups.bucket },
        { name = "S3_PREFIX", value = "takeout" },
        { name = "GOOGLE_OAUTH_SECRET_ARN", value = aws_secretsmanager_secret.google_oauth.arn },
        { name = "SNS_TOPIC_ARN", value = aws_sns_topic.alerts.arn },
        { name = "DRIVE_FOLDER", value = "Takeout" },
        # Guard against syncing a Takeout export that's still mid-generation:
        # skip files modified more recently than this many hours ago.
        { name = "MIN_FILE_AGE_HOURS", value = "6" },
        { name = "AWS_REGION_NAME", value = var.aws_region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backup.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "backup"
        }
      }
    }
  ])

  tags = {
    Project = var.project_name
  }
}
