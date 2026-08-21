# Uses your account's default VPC and its public subnets. The task runs
# 6x/year for a few hours at most, so a NAT Gateway (~£25-30/month) isn't
# worth it — the task gets a public IP directly and reaches Google/AWS APIs
# via the internet gateway. All inbound traffic is blocked; only outbound
# is allowed, so this is not the same risk profile as hosting a service.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "backup_task" {
  name        = "${var.project_name}-task-sg"
  description = "Outbound-only SG for the Takeout backup Fargate task"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "Allow all outbound (Google APIs, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = var.project_name
  }
}
