# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}

# Create S3 backend
terraform {
  backend "s3" {
    bucket         = "my-tfstate-bucket-jj"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform"
  }
}

#VPC module
module "vpc" {
  source            = "./modules/terraform-vpc"
  vpc_cidr_block    = "10.0.0.0/16"
  pub_cidr_block    = ["10.0.0.0/18", "10.0.64.0/18"]
  priv_cidr_block   = ["10.0.128.0/18", "10.0.192.0/18"]
  az                = ["us-east-1a", "us-east-1b"]
  nat_gateway_count = 1
  //variable "shared_credentials_file" {}
  enable_dns_support   = true
  enable_dns_hostnames = true
}

#EC2 module
module "ec2" {
  source    = "./modules/terraform-ec2"
  user_data = file("./modules/terraform-ec2/install_apache.sh")
  #user_data = file("${path.module}/install_apache.sh")
  subnet_id         = module.vpc.private_subnet1
  alb_subnet        = module.vpc.public_subnets
  as_subnet        = module.vpc.private_subnets
  vpc_id            = module.vpc.vpc_id
  ec2_instance_type = "t2.micro"
  #IsUbuntu = false
  key_name                     = "deployer-key"
  public_key                   = file("../.ssh/id_rsa.pub")
  device_name                  = "/dev/sdf"
  volume_type                  = "gp2"
  volume_size                  = 60
  alb_name                     = "lb-tf"
  internal                     = false
  load_balancer_type           = "application"
  healthy_threshold            = 3
  tg_name                      = "aws-lb-tg"
  tg_interval                  = 40
  target_type                  = "instance"
  deregistration_delay         = 30
  tg_protocol                  = "HTTP"
  matcher                      = "200,302"
  tg_timeout                   = 30
  tg_port                      = "80"
  tg_path                      = "/"
  unhealthy_threshold          = 2
  as_instance_type             = "t2.micro"
  as_instance_name             = "web_config"
  as_group_name                = "autoscalegroup"
  as_min_size                  = 1
  as_max_size                  = 2
  as_health_check_grace_period = 30
  as_health_check_type         = "EC2"
  as_force_delete              = true
  as_group_policy_name         = "autoscalegroup_policy"
  as_scaling_adjustment        = 2
  as_scaling_adjustment_type   = "ChangeInCapacity"
  as_cooldown                  = 300
}