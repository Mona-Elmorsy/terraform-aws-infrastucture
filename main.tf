resource "aws_vpc" "main" {
  cidr_block = "192.168.0.0/16"
  tags = {
       Name = "main-vpc"
    }
}

############################
# Internet Gateway
############################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-gateway"
    }
}

############################
# Public Subnets
############################

resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
       Name = "pub_subnet-1"
    }
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
       Name = "pub_subnet-2"
    }
}

############################
# Private Subnets
############################

resource "aws_subnet" "private_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.3.0/24"
  availability_zone = "us-east-1a"
  tags = {
       Name = "priv_subnet-1"
    }
}

resource "aws_subnet" "private_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.4.0/24"
  availability_zone = "us-east-1b"
  tags = {
       Name = "priv_subnet-2"
    }
}

############################
# NAT Gateway
############################

resource "aws_eip" "nat_eip" {
 tags = {
    Name = "nat-eip"
    }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_az1.id
  tags = {
    Name = "main-natgateway"
    }
}

############################
# Route Tables
############################

# Public Route Table → IGW
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "public_RT"
    }
}

resource "aws_route_table_association" "public_1_assoc" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2_assoc" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public_rt.id
}

# Private Route Table → NAT
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name = "private_RT"
    }
}

resource "aws_route_table_association" "private_1_assoc" {
  subnet_id      = aws_subnet.private_az1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_2_assoc" {
  subnet_id      = aws_subnet.private_az2.id
  route_table_id = aws_route_table.private_rt.id
}

############################
# S3 Bucket
############################

resource "aws_s3_bucket" "app_bucket" {
  bucket        = "my-terraform-arch-bucket-123456"
  force_destroy = true
}

############################
# IAM Role + Policy (EC2 → S3)
############################

resource "aws_iam_role" "ec2_role" {
  name = "ec2_s3_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_policy" {
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:*"]
      Resource = [
        "arn:aws:s3:::my-terraform-arch-bucket-123456",
        "arn:aws:s3:::my-terraform-arch-bucket-123456/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  role = aws_iam_role.ec2_role.name
}

############################
# Security Groups
############################

resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
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
}
resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [ aws_security_group.alb_sg.id ]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [aws_security_group.jumper_ec2_sg.id]
   }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "jumper_ec2_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    }
}
############################
# Launch Template (Python App)
############################

resource "aws_launch_template" "app_lt" {
  image_id      = "ami-0f3caa1cf4417e51b"
  instance_type = "t2.micro"
  key_name = "ec2c-key"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  vpc_security_group_ids = [ aws_security_group.ec2_sg.id ]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3

    cat <<EOT > /home/ec2-user/index.html
    Hello from $(hostname)
    EOT

    cd /home/ec2-user
    nohup python3 -m http.server 80 --bind 0.0.0.0 > server.log 2>&1 &
    EOF
  )
  
}

############################
# ALB
############################

resource "aws_lb" "alb" {
  load_balancer_type = "application"
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
  security_groups    = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "tg" {
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    protocol = "HTTP"
    path = "/" 
    }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

############################
# Auto Scaling Group (1–3)
############################

resource "aws_autoscaling_group" "asg" {
  min_size            = 1
  max_size            = 3
  desired_capacity    = 2
  vpc_zone_identifier = [aws_subnet.private_az1.id, aws_subnet.private_az2.id]

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.tg.arn]
}

############################
# jumper ec2
############################

resource "aws_instance" "jumper_ec2" {
  ami = "ami-0f3caa1cf4417e51b"
  instance_type = "t2.micro"
  subnet_id = aws_subnet.public_az2.id
  vpc_security_group_ids = [aws_security_group.jumper_ec2_sg.id]
  associate_public_ip_address = true
  key_name = "ec2c-key"
  tags = {
  Name = "jump server"
    }
}