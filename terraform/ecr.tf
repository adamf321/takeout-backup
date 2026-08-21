resource "aws_ecr_repository" "backup" {
  name                 = "${var.project_name}-runner"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_ecr_lifecycle_policy" "backup" {
  repository = aws_ecr_repository.backup.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.backup.repository_url
  description = "Push your container image here (see README for docker build/push commands)"
}
