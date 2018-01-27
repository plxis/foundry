variable "name"   {  }
variable "users"  { type = "list", default = [] }
variable "policy" {  }

resource "aws_iam_group" "group" {
  name = "${var.name}"
}
resource "aws_iam_group_policy" "group-policy" {
  name = "group-policy-${var.name}"
  group = "${aws_iam_group.group.id}"
  policy = "${var.policy}"
}

resource "aws_iam_group_membership" "group-membership" {
  name = "group-membership-${var.name}"

  group = "${aws_iam_group.group.id}"
  users = [ "${var.users}" ]
}

output "group_name" {
  value = "aws_iam_group.group.name"
}