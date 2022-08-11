locals {
  env = "mytest"
}

//EC2 instance AMI

data "aws_ami" "amzlinux2" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm*"]
  }
}

resource "aws_key_pair" "deployer1" {
  key_name   = var.key_name
  public_key = var.public_key
}

resource "tls_private_key" "ec2key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ec2key.private_key_pem
  filename        = var.private_key_file_path
  file_permission = "0400"
}

resource "aws_key_pair" "deployer" {
  key_name   = split(".", "${var.private_key_file_path}")[0]
  public_key = tls_private_key.ec2key.public_key_openssh
}

//IAM role

resource "aws_iam_role" "s3_role" {
  name = "s3-ec2-role"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3-access" {
  role       = aws_iam_role.s3_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_instance_profile" "new_profile" {
  name = "new_profile"
  role = aws_iam_role.s3_role.name
}

# change USERDATA varible value after grabbing RDS endpoint info
data "template_file" "user_data" {
  template = var.IsUbuntu ? var.userdata_option1 : var.userdata_option2
  vars = {
    db_username      = var.database_user
    db_user_password = var.database_password
    db_name          = var.database_name
    db_RDS           = aws_db_instance.DataBase.endpoint
  }
}

//Creating 2 EC2 instances using count

resource "aws_instance" "inst1" {
  count                  = var.ec2_instance_type == "t2.micro" ? 1 : 0
  ami                    = data.aws_ami.amzlinux2.id
  instance_type          = var.ec2_instance_type
  iam_instance_profile   = aws_iam_instance_profile.new_profile.id
  subnet_id              = var.subnet_id
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.sec_group1.id]
  user_data              = data.template_file.user_data.rendered
  ebs_block_device {
    device_name = var.device_name
    volume_size = var.volume_size
    volume_type = var.volume_type
  }
  depends_on = [aws_security_group.sec_group1, aws_security_group.alb_sec_group1, aws_security_group.SG_private_subnet_, aws_db_instance.DataBase]
  tags = {
    Name = title("${local.env}-ec2-instance")
  }
}

//Application load balancer [created security group and ALB]

resource "aws_security_group" "alb_sec_group1" {
  #name        = "allow_tls"
  #description = "Allow TLS inbound traffic"
  vpc_id = var.vpc_id

  ingress {
    description = "Http access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = {
    Name = title("${local.env}-alb-sg")
  }
}

resource "aws_lb" "app_lb" {
  name               = var.alb_name
  internal           = var.internal
  load_balancer_type = var.load_balancer_type
  security_groups    = [aws_security_group.alb_sec_group1.id]
  //subnets            = [element(aws_subnet.public_subnet.*.id,0), element(aws_subnet.public_subnet.*.id,1)]
  subnets = flatten([var.alb_subnet])

  //  enable_deletion_protection = true

  //  access_logs {
  //    bucket  = aws_s3_bucket.lb_logs.bucket
  //    prefix  = "test-lb"
  //    enabled = true
  //  }

  tags = {
    Environment = title("${local.env}-alb")
  }
}


//Creating target group with health check

resource "aws_lb_target_group" "aws-tg" {
  name                 = var.tg_name
  port                 = var.tg_port
  deregistration_delay = var.deregistration_delay
  protocol             = var.tg_protocol
  vpc_id               = var.vpc_id
  target_type          = var.target_type

  health_check {
    healthy_threshold   = var.healthy_threshold
    interval            = var.tg_interval
    protocol            = var.tg_protocol
    matcher             = var.matcher
    timeout             = var.tg_timeout
    port                = var.tg_port
    path                = var.tg_path
    unhealthy_threshold = var.unhealthy_threshold
  }

  tags = {
    Name = title("${local.env}-test-target-group")
  }
}

//Target group attachment
resource "aws_lb_target_group_attachment" "lb-tgattach" {
count            = length(aws_instance.inst1.*.id)
target_group_arn = aws_lb_target_group.aws-tg.arn
target_id        = element(aws_instance.inst1.*.id, count.index)
port             = 80
}


//ALB listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = var.tg_port
  protocol          = var.tg_protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws-tg.arn
  }
}

//EC2-ALB security group and security rule

//EC2 security group

resource "aws_security_group" "sec_group1" {
  #name        = "allow_tls"
  #description = "Allow TLS inbound traffic"
  vpc_id = var.vpc_id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description      = "SSH access"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    security_groups = [aws_security_group.bastion_host.id]
  }  

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group_rule" "sg-rule" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_sec_group1.id
  security_group_id        = aws_security_group.sec_group1.id
}


# Creating the autoscaling launch configuration that contains AWS EC2 instance details
resource "aws_launch_configuration" "aws_autoscale_conf" {
  # Defining the name of the Autoscaling launch configuration
  name = var.as_instance_name
  # Defining the image ID of AWS EC2 instance
  image_id = data.aws_ami.amzlinux2.id
  # Defining the instance type of the AWS EC2 instance
  instance_type = var.as_instance_type
  # Defining the Key that will be used to access the AWS EC2 instance
  key_name        = aws_key_pair.deployer.key_name
  user_data       = data.template_file.user_data.rendered
  security_groups = [aws_security_group.sec_group1.id]
}


# Creating the autoscaling group within us-east-1a availability zone
resource "aws_autoscaling_group" "mygroup" {
  # Specifying the name of the autoscaling group
  name = var.as_group_name
  # Defining the maximum number of AWS EC2 instances while scaling
  max_size = var.as_max_size
  # Defining the minimum number of AWS EC2 instances while scaling
  min_size = var.as_min_size
  # Grace period is the time after which AWS EC2 instance comes into service before checking health.
  health_check_grace_period = var.as_health_check_grace_period
  # The Autoscaling will happen based on health of AWS EC2 instance defined in AWS CLoudwatch Alarm 
  health_check_type = var.as_health_check_type
  # force_delete deletes the Auto Scaling Group without waiting for all instances in the pool to terminate
  force_delete = var.as_force_delete
  # Defining the termination policy where the oldest instance will be replaced first 
  termination_policies = ["OldestInstance"]
  # Scaling group is dependent on autoscaling launch configuration because of AWS EC2 instance configurations
  launch_configuration = aws_launch_configuration.aws_autoscale_conf.name
  vpc_zone_identifier  = flatten([var.as_subnet])
}
# Creating the autoscaling schedule of the autoscaling group

//resource "aws_autoscaling_schedule" "mygroup_schedule" {
//  scheduled_action_name  = "autoscalegroup_action"
//# The minimum size for the Auto Scaling group
//  min_size               = 1
//# The maxmimum size for the Auto Scaling group
//  max_size               = 2
//# Desired_capacity is the number of running EC2 instances in the Autoscaling group
//  desired_capacity       = 1
//# defining the start_time of autoscaling if you think traffic can peak at this time.
//  start_time             = "2022-02-09T18:00:00Z"
//  autoscaling_group_name = aws_autoscaling_group.mygroup.name
//}


# Creating the autoscaling policy of the autoscaling group
resource "aws_autoscaling_policy" "mygroup_policy" {
  name = var.as_group_policy_name
  # The number of instances by which to scale.
  scaling_adjustment = var.as_scaling_adjustment
  adjustment_type    = var.as_scaling_adjustment_type
  # The amount of time (seconds) after a scaling completes and the next scaling starts.
  cooldown               = var.as_cooldown
  autoscaling_group_name = aws_autoscaling_group.mygroup.name
}

resource "aws_autoscaling_attachment" "asg_attachment_bar" {
  autoscaling_group_name = aws_autoscaling_group.mygroup.id
  lb_target_group_arn    = aws_lb_target_group.aws-tg.arn
}

///RDS START

#EC2 for bastion host 
resource "aws_instance" "bastion_host" {
  ami           = data.aws_ami.amzlinux2.id
  instance_type = var.rds_instance_type
  subnet_id = var.pb_subnet
  key_name = aws_key_pair.deployer1.key_name
  vpc_security_group_ids = [aws_security_group.bastion_host.id]      
  tags = {
     Name = title("${local.env}-bastion_host")
  } 

provisioner "file" {
    source = var.source_key
    destination = var.destination_key
    
    connection {
      type = "ssh"
      user = "ec2-user"
      private_key = var.private_key_path
      host = aws_instance.bastion_host.public_ip
    }
}
}

# Launching RDS db instance
resource "aws_db_instance" "DataBase" {
  allocated_storage    = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  storage_type         = var.rds_storage_type
  engine               = var.rds_engine
  engine_version       = var.rds_engine_version
  instance_class       = var.rds_instance_class
  db_name                 = "${var.database_name}"
  username             = "${var.database_user}"
  password             = "${var.database_password}"
  port = var.rds_port
  parameter_group_name = var.rds_pm_groupname
  publicly_accessible = false
  db_subnet_group_name = var.db_subnet_name
  vpc_security_group_ids = [aws_security_group.SG_private_subnet_.id]
  skip_final_snapshot = true 

provisioner "local-exec" {
  command = "echo ${aws_db_instance.DataBase.endpoint} > DB_host.txt"
    }
}

# Creating security group for bastion host
resource "aws_security_group" "bastion_host" {
  name        = "bastion_host_SG"
  description = "Allow SSH"
  vpc_id      =  var.vpc_id             

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
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


# Creating a new security group for RDS 
resource "aws_security_group" "SG_private_subnet_" {
  name        = "MYSQL_security_group"
  description = "MYSQL"
  vpc_id      = var.vpc_id              

  ingress {
    description = "MYSQL Port"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.sec_group1.id, aws_security_group.bastion_host.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
