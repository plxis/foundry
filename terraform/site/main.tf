# Variables
variable "profile"        { default = "int" }
variable "context"        { description = "Logical identifier for related resources" }
variable "region"         { }
variable "cidr_base"      {
  description = "Base IP (2 octets, ex: '172.4') for VPC CIDR"
  default = "172.4"
}
variable "availability_zones" { type = "map"
  default = {
    "us-east-1" = { 
      "a" = "us-east-1c"
      "b" = "us-east-1d"
    }
  }
}
variable "public_dns_zone"    { }
variable "private_dns_zone"   { default = "site.local" }
variable "ip_whitelist"       { type="list", default = [] }
variable "users"              { type="map", default = {} }
variable "gsuite_admin_email" { }
variable "gsuite_secret"      { }
variable "ses_enabled"        { description = "'true' if SES support (and domain verification records) should be enabled"}
variable "work_dir"           { default = "" }

# Users
# This approach causes a benign error during a destroy operation.
# It is due to the fact that Terraform does not set the 'result'
# attribute during the destroy operation, and there is no way
# to query for its existence. See below for related issues:
#   - https://github.com/hashicorp/terraform/issues/16008
#   - https://github.com/hashicorp/terraform/issues/15983
# This goes away with the transpose(map) function.
data "external" "add_users" {
  depends_on = ["local_file.user_list"]
  program = [ "python", "${path.module}/provisionUsers.py", "add", "${local_file.user_list.filename}", "${var.context}" ]
  query   = "${var.users}"
}

locals {
  # These provide default empty list values for each group
  # because Terraform fails if a key doesn't exist in a map.
  default_groups = {
    "Admins"        = ""
    "Viewers"       = ""
  }

  # Pending PR-16002 (https://github.com/hashicorp/terraform/pull/16002)
  # In the absence of the transpose() function, we have to find another
  # combination of functions to arrive at this list. For now, we will
  # use the custom external data source.
  groups = "${merge(local.default_groups, data.external.add_users.result)}"
  users = "${keys(var.users)}"
  uniqueId = "${substr(uuid(), 0, 4)}"
  rolePrefix = "sso-${var.context}-"
  roleSuffix = "-${local.uniqueId}"
}

# -----------------------------------------------------------------------------
# Main configuration
# -----------------------------------------------------------------------------
terraform {
  backend "s3" { }
}

data "aws_caller_identity" "current" { }

provider "aws" {
  region = "${var.region}"
  profile= "${var.profile}"
}

# DNS
resource "aws_route53_zone" "public-zone" {
  name = "${var.public_dns_zone}"
  comment = "public-zone-${var.context}-${var.region}"
  tags {
    Name        = "public-zone-${var.context}-${var.region}"
    Context     = "${var.context}"
  }
}

resource "aws_route53_zone" "private-zone" {
  name = "${var.private_dns_zone}"
  comment = "private-zone-${var.context}-${var.region}"
  vpc_id = "${module.site-us-east.vpc_id}"
  tags {
    Name        = "private-zone-${var.context}-${var.region}"
    Context     = "${var.context}"
  }
}


# Network
module "site-us-east" {
  source = "./modules/site"
  context = "${var.context}"
  region = "${var.region}"
  cidr_base = "${var.cidr_base}"
  availability_zones = "${var.availability_zones[var.region]}"
  zone_id = "${aws_route53_zone.public-zone.id}"
}

# Federation
data "template_file" "saml-federation-role-policy-template" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  template = "${file("${path.module}/templates/saml-federation-role-policy.json")}"

  vars {
    entity = "${aws_iam_saml_provider.g-suite.arn}"
  }
}

resource "aws_iam_saml_provider" "g-suite" {
  count                  = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  name                   = "${var.context}-G-Suite"
  saml_metadata_document = "${file("${path.module}/templates/idp-saml-metadata.xml")}"
}


# Admin Role Configuration
resource "aws_iam_role" "saml-federation-admin" {
  count              = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  name               = "${local.rolePrefix}admin"
  assume_role_policy = "${data.template_file.saml-federation-role-policy-template.rendered}"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_policy" "role-policy-admin" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  name  = "${local.rolePrefix}admin"
  policy = "${file("${path.module}/templates/group-policy-admins.json")}"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "role-policy-attachment-admin" {
  count      = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  depends_on = [ "aws_iam_policy.role-policy-admin", "aws_iam_role.saml-federation-admin" ]
  role       = "${aws_iam_role.saml-federation-admin.name}"
  policy_arn = "${aws_iam_policy.role-policy-admin.arn}"
}

module "admins-group" {
  source = "./modules/group"
  name   = "${var.context}-Admins"
  users  = "${split(",", local.groups["Admins"])}"
  policy = "${file("${path.module}/templates/group-policy-admins.json")}"
}


# Viewer Role Configuration
resource "aws_iam_role" "saml-federation-viewer" {
  count              = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  name               = "${local.rolePrefix}viewer"
  assume_role_policy = "${data.template_file.saml-federation-role-policy-template.rendered}"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_policy" "role-policy-viewer" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  name  = "${local.rolePrefix}viewer"
  policy = "${file("${path.module}/templates/group-policy-viewers.json")}"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "role-policy-attachment-viewer" {
  count      = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  depends_on = [ "aws_iam_policy.role-policy-viewer", "aws_iam_role.saml-federation-admin" ]
  role       = "${aws_iam_role.saml-federation-viewer.name}"
  policy_arn = "${aws_iam_policy.role-policy-viewer.arn}"
}

module "viewers-group" {
  source = "./modules/group"
  name   = "${var.context}-Viewers"
  users  = "${split(",", local.groups["Viewers"])}"
  policy = "${file("${path.module}/templates/group-policy-viewers.json")}"
}

# Basic Role Configuration
resource "aws_iam_role" "saml-federation-selfkey" {
  count              = "${var.gsuite_secret == "NONE" ? 0 : length(local.users)}"
  name               = "${local.rolePrefix}${element(local.users, count.index)}${local.roleSuffix}"
  assume_role_policy = "${data.template_file.saml-federation-role-policy-template.rendered}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_policy" "role-policy-selfkey" {
  count = "${var.gsuite_secret == "NONE" ? 0 : length(local.users)}"
  name  = "${local.rolePrefix}${element(local.users, count.index)}${local.roleSuffix}"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:GetLoginProfile",
        "iam:*AccessKey*",
        "iam:*SSHPublicKey*"
      ],
      "Resource": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.context}/${element(local.users, count.index)}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:ListAccount*",
        "iam:GetAccountSummary",
        "iam:GetAccountPasswordPolicy",
        "iam:ListUsers"
      ],
      "Resource": "*"
    }
  ]
}
EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "role-policy-attachment-selfkey" {
  depends_on = [ "aws_iam_policy.role-policy-selfkey", "aws_iam_role.saml-federation-selfkey" ]
  count      = "${var.gsuite_secret == "NONE" ? 0 : length(local.users)}"
  role       = "${element(aws_iam_role.saml-federation-selfkey.*.name, count.index)}"
  policy_arn = "${element(aws_iam_policy.role-policy-selfkey.*.arn, count.index)}"
}


resource "local_file" "gsuite_secret_json" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  content  = "${base64decode(var.gsuite_secret)}"
  filename = "${var.work_dir}/secret.json"
}

resource "local_file" "user_list" {
  content = "${jsonencode(local.users)}"
  filename = "${var.work_dir}/users.json"
}

resource "local_file" "user_group_map" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  content = "${jsonencode(var.users)}"
  filename = "${var.work_dir}/user_groups.json"
}

resource "null_resource" "link_roles_to_gsuite" {
  count    = "${var.gsuite_secret == "NONE" ? 0 : 1}"
  # Changes to the list of role IDs require re-connecting G-Suite users to IAM user roles
  triggers {
    role_ids = "${join(",", aws_iam_role.saml-federation-selfkey.*.id)}"
  }

  provisioner "local-exec" {
    command = "python ${path.module}/linkGsuiteAws.py -- ${var.gsuite_admin_email} ${local_file.gsuite_secret_json.filename} ${aws_iam_saml_provider.g-suite.arn} ${local_file.user_group_map.filename} ${local.rolePrefix} ${local.roleSuffix}"
  }
}

resource "null_resource" "delete_users" {
  # Changes to the list of role IDs require deprovisioning users.
  triggers {
    role_ids = "${join(",", local.users)}"
  }
  depends_on = ["module.admins-group","module.viewers-group"]

  provisioner "local-exec" {
    command = "python ${path.module}/provisionUsers.py delete ${local_file.user_list.filename} ${var.context}"
  }
}

# Logging
resource "aws_cloudtrail" "site-cloudtrail" {
  name                          = "trail-${var.context}-${var.region}"
  s3_bucket_name                = "${aws_s3_bucket.cloudtrail.id}"
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = false

  tags {
    Name        = "vpc-${var.context}-${var.region}"
    Context     = "${var.context}"
  }
}

data "template_file" "cloud-trail-bucket-policy-template" {
  template = "${file("${path.module}/templates/cloudtrail-bucket-policy.json")}"

  vars {
    bucket = "ct-${var.context}-${var.region}"
  }
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "ct-${var.context}-${var.region}"
  force_destroy = true

  policy = "${data.template_file.cloud-trail-bucket-policy-template.rendered}"
}

# Email (SES)
module "ses-email" {
  enabled = "${var.ses_enabled}"
  source = "./modules/email"
  domain_name = "${var.public_dns_zone}"
  zone_id = "${aws_route53_zone.public-zone.id}"
}

# Outputs
output "context" {
  value = "${var.context}"
}

output "vpc_id" {
  value = "${module.site-us-east.vpc_id}"
}

output "vpc_nat_public_ip" {
  value = "${module.site-us-east.vpc_nat_public_ip}"
}

output "private_subnets" {
  value = [ "${module.site-us-east.subnet_private_a}", "${module.site-us-east.subnet_private_b}" ]
}

output "public_subnets" {
  value = [ "${module.site-us-east.subnet_public_a}", "${module.site-us-east.subnet_public_b}" ]
}

output "public_zone_id" {
  value = "${aws_route53_zone.public-zone.zone_id}"
}

output "private_zone_id" {
  value = "${aws_route53_zone.private-zone.zone_id}"
}


output "public_zone_ns" {
  value = "${aws_route53_zone.public-zone.name_servers}"
}

output "ip_whitelist" {
  value = "${var.ip_whitelist}"
}

output "users_to_groups" {
  value = "${var.users}"
}

output "groups_to_users" {
  value = "${local.groups}"
}

output "users" {
  value = "${local.users}"
}

output "jump_host_private_key" {
  sensitive = true
  value = "${module.site-us-east.jump_private_key}"
}

output "jump_host_sg" {
  value = "${module.site-us-east.jump_sg}"
}

output "jump_host_dns" {
  value = "${module.site-us-east.jump_elb_dns}"
}

output "foundry_log_group" {
  value = "${module.site-us-east.log_group}"
}

output "user_data_efs_dns_name" {
  value = "${module.site-us-east.user_data_efs_dns_name}"
}

output "role_prefix" {
  value = "${local.rolePrefix}"
}

output "role_suffix" {
  value = "${local.roleSuffix}"
}

output "availability_zones" {
  value = "${var.availability_zones[var.region]}"
}