terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# 1) VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project_name}-vpc" }
}

# 2) Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# 3) Public subnets (explicit AZ mapping from variables)
resource "aws_subnet" "public" {
  for_each                = var.public_subnet_cidrs
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-${each.key}" }
}

# 4) Private subnets (explicit AZ mapping from variables)
resource "aws_subnet" "private" {
  for_each          = var.private_subnet_cidrs
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags = { Name = "${var.project_name}-private-${each.key}" }
}

# 5) NAT Gateway (EIP + NAT in first public subnet)
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

locals {
  # choose the first public subnet deterministically
  first_public_subnet_id = values(aws_subnet.public)[0].id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = local.first_public_subnet_id
  tags          = { Name = "${var.project_name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# 6) Route tables
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route" "public_internet_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_rt.id
}

# 7) Security Groups
resource "aws_security_group" "elb_sg" {
  name        = "${var.project_name}-elb-sg"
  description = "ELB SG allows HTTP from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-elb-sg" }
}

resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-ec2-sg"
  description = "EC2 SG allows only from ELB SG on 8080"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App traffic from ELB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.elb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# 8) IAM Role + Instance Profile
resource "aws_iam_role" "ec2_role" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_logs_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# 9) Classic ELB
resource "aws_elb" "app_elb" {
  name            = "${var.project_name}-elb"
  # attach one subnet per AZ (using AZ-mapped public subnets)
  subnets         = [for s in values(aws_subnet.public) : s.id]
  security_groups = [aws_security_group.elb_sg.id]

  listener {
    instance_port     = 8080
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    target              = "HTTP:8080/health"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.project_name}-elb" }
}

# 10) AMI + user_data
data "aws_ami" "amazon_linux2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

locals {
  user_data = <<-EOT
    #!/bin/bash
    set -eux
    yum update -y
    yum install -y python3
    pip3 install flask

    cat <<'PY' > /opt/server.py
    from flask import Flask
    app = Flask(__name__)

    @app.route("/")
    def home():
        return "Hello from private EC2 behind ELB!"

    @app.route("/health")
    def health():
        return "ok"

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=8080)
    PY

    cat <<'UNIT' > /etc/systemd/system/restapp.service
    [Unit]
    Description=REST API Flask App
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /opt/server.py
    Restart=always
    RestartSec=5
    StandardOutput=journal
    StandardError=journal
    User=root

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable restapp
    systemctl start restapp
  EOT
}

# 11) Launch Template
resource "aws_launch_template" "app_lt" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = data.aws_ami.amazon_linux2.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  user_data              = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-app"
    }
  }
}

# 12) Auto Scaling Group
resource "aws_autoscaling_group" "app_asg" {
  name                      = "${var.project_name}-asg"
  desired_capacity          = var.desired_capacity
  min_size                  = var.min_size
  max_size                  = var.max_size
  vpc_zone_identifier       = [for s in values(aws_subnet.private) : s.id]
  health_check_type         = "ELB"
  health_check_grace_period = 60
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  # Classic ELB attachment
  load_balancers = [aws_elb.app_elb.name]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
