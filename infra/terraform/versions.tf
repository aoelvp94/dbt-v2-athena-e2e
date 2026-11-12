# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.9.8, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
  }

  # Local state lives next to these files. infra/.gitignore and the repo
  # .gitignore keep *.tfstate and .terraform/ out of git so up/destroy cycles
  # stay on this machine and nothing is left in a remote backend.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = var.project_tag
    }
  }
}
