resource "aws_cloudwatch_log_group" "foundry" {
  name = "${var.context}"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "foundry_flow" {
  name = "${var.context}-flow"
  retention_in_days = 90
}

resource "aws_flow_log" "foundry" {
  log_group_name = "${aws_cloudwatch_log_group.foundry_flow.name}"
  iam_role_arn   = "${aws_iam_role.flow-log-role.arn}"
  vpc_id         = "${aws_vpc.main.id}"
  traffic_type   = "ALL"
}

resource "aws_iam_role" "flow-log-role" {
  name = "flow-log-role-${var.context}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "flow-log-role-policy" {
  name = "flow-log-role-policy-${var.context}"
  role = "${aws_iam_role.flow-log-role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}