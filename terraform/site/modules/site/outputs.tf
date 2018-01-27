output "vpc_id" {
  value = "${aws_vpc.main.id}"
}

output "vpc_nat_public_ip" {
  value = "${aws_nat_gateway.nat-gw.public_ip}"
}

output "subnet_private_a" {
  value = "${aws_subnet.private-a.id}"
}

output "subnet_public_a" {
  value = "${aws_subnet.public-a.id}"
}

output "subnet_private_b" {
  value = "${aws_subnet.private-b.id}"
}

output "subnet_public_b" {
  value = "${aws_subnet.public-b.id}"
}

output "jump_private_key" {
  value = "${tls_private_key.jump-tls-key.private_key_pem}"
  sensitive = true
}

output "jump_sg" {
  value = "${aws_security_group.jump-sg.id}"
}

output "log_group" {
  value = "${aws_cloudwatch_log_group.foundry.arn}"
}

output "jump_elb_dns" {
  value = "${aws_elb.jump-elb.dns_name}"
}

output "user_data_efs_dns_name" {
  # Manually constructing DNS name until Terraform supports retrieving dns_name from aws_efs_file_system
  value = "${aws_efs_file_system.user_fs.id}.efs.${var.region}.amazonaws.com"
}