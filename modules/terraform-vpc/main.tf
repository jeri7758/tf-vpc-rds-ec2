locals {
  env = "mytest"
}

//VPC
resource "aws_vpc" "my-vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = {
    Name = title("${local.env}-vpc")
  }
}

//Subnets
//2 public subnets
resource "aws_subnet" "public_subnet" {
  count                   = length(var.pub_cidr_block)
  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = element(var.pub_cidr_block, count.index)
  map_public_ip_on_launch = true
  availability_zone       = element(var.az, count.index)

  tags = {
    Name = title("${local.env}-public-subnet-${count.index}")
  }
}

//2 private subnets
resource "aws_subnet" "private_subnet" {
  count             = length(var.priv_cidr_block)
  vpc_id            = aws_vpc.my-vpc.id
  map_public_ip_on_launch = false
  cidr_block        = element(var.priv_cidr_block, count.index)
  availability_zone = element(var.az, count.index)

  tags = {
    Name = title("${local.env}-private-subnet-${count.index}")
  }
}


//Internet gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = title("${local.env}-igw")
  }
}

//EIP
resource "aws_eip" "elastic_ip" {
  depends_on = [aws_internet_gateway.gw]
  vpc        = true

  tags = {
    Name = title("${local.env}-eip")
  }
}

//NAT
resource "aws_nat_gateway" "nat" {
  count         = var.nat_gateway_count
  allocation_id = element(aws_eip.elastic_ip.*.id, count.index)
  subnet_id     = element(aws_subnet.public_subnet.*.id, count.index)

  tags = {
    Name = title("${local.env}-nat")
  }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  # on the Internet Gateway for the VPC.
  depends_on = [aws_internet_gateway.gw]
}

//Public route -attached to gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = title("${local.env}-public-route-table")
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

//we can create route seperately too
//resource "aws_route" "public-internet-gateway" {
//route_table_id            = aws_route_table.public.id
//destination_cidr_block    = "0.0.0.0/0"
//gateway_id = aws_internet_gateway.gw.id
//}

//private route-attached to NAT
resource "aws_route_table" "private" {
  count  = length(aws_nat_gateway.nat.*.id)
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = title("${local.env}-private-route-table")
  }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.nat.*.id, count.index)
  }
}

//we can create route seperately too
//resource "aws_route" "private-internet-gateway" {
//route_table_id            = aws_route_table.private.id
//destination_cidr_block    = "0.0.0.0/0"
//gateway_id = aws_nat_gateway.nat.id
//}


//PUBLIC ROUTE TABLE ASSOCIATION
resource "aws_route_table_association" "public_subnet" {
  count          = length(aws_subnet.public_subnet.*.id)
  subnet_id      = element(aws_subnet.public_subnet.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

//PRIVATE ROUTE TABLE ASSOCIATION
resource "aws_route_table_association" "private_subnet" {
  count          = length(aws_subnet.private_subnet.*.id)
  subnet_id      = element(aws_subnet.private_subnet.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

//Creating db subnet group for rds
resource "aws_db_subnet_group" "db_subnet" {
  name       = "rds_db"
  subnet_ids = flatten([aws_subnet.private_subnet.*.id])

  tags = {
    Name = title("${local.env}-My DB subnet group")
  }
}