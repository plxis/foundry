variable "context"                         { }
variable "region"                          { }
variable "cidr_base"                       { }
variable "cidr_whitelist"                  { default="0.0.0.0/0" }
variable "availability_zones"              { type="map" }
variable "zone_id"                         { }
variable "jumphost_instance_type"          { default = "t2.nano" }
variable "jumphost_instance_count_min"     { default = 1 }
variable "jumphost_instance_count_max"     { default = 2 }
variable "jumphost_instance_count_desired" { default = 1 }

locals {
  subnets = ["${aws_subnet.private-a.id}","${aws_subnet.private-b.id}"]
}