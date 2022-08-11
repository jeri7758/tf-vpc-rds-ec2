output "vpc_id" {
  value = aws_vpc.my-vpc.id
}

output "private_subnet1" {
    value = element(aws_subnet.private_subnet.*.id,0)
}

output "public_subnets" {
  value = "${(aws_subnet.public_subnet.*.id)}"
}

output "private_subnets" {
  value = "${(aws_subnet.private_subnet.*.id)}"
}