terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure if you want remote state (recommended once this
  # is working — local state is fine to get started).
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "takeout-s3-backup/terraform.tfstate"
  #   region = "eu-west-2"
  # }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
