variable "project_name" {
  type        = string
  default     = "one-click-rest-api"
  description = "Project name prefix"
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR"
}

# Public subnets across different AZs
variable "public_subnet_cidrs" {
  description = "Public subnets across different AZs"
  type = map(string)
  default = {
    "us-east-1a" = "10.0.1.0/24"
    "us-east-1b" = "10.0.2.0/24"
  }
}

# Private subnets across different AZs
variable "private_subnet_cidrs" {
  description = "Private subnets across different AZs"
  type = map(string)
  default = {
    "us-east-1a" = "10.0.11.0/24"
    "us-east-1b" = "10.0.12.0/24"
  }
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
}

variable "desired_capacity" {
  type        = number
  default     = 2
}

variable "min_size" {
  type        = number
  default     = 2
}

variable "max_size" {
  type        = number
  default     = 4
}
