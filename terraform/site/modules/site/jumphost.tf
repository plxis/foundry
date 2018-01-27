data "template_file" "user-data" {
  template = "${file("${path.module}/jump-bootstrap.tpl")}"
  vars {
    context = "${var.context}"
    users_mount    = "/users"
    users_efs      = "${aws_efs_mount_target.jump_fs_target.0.dns_name}"
    log_group      = "${aws_cloudwatch_log_group.foundry.name}"    
  }
}

resource "tls_private_key" "jump-tls-key" {
  algorithm   = "RSA"
}

resource "aws_key_pair" "jump-key" {
  key_name   = "${var.context}"
  public_key = "${tls_private_key.jump-tls-key.public_key_openssh}"
}

resource "aws_security_group" "jump-sg" {
  name   = "jump-${var.context}"
  vpc_id = "${aws_vpc.main.id}"

  ingress {
      from_port       = 22
      to_port         = 22
      protocol        = "tcp"
      security_groups = [ "${aws_elb.jump-elb.source_security_group_id}" ]
  }

  egress {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "${var.context}-jumphost"
    Context = "${var.context}"
  }
}

data "aws_iam_policy_document" "jump-assume-role-policy-document" {
  statement {
    actions = [ "sts:AssumeRole" ]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = [ "ec2.amazonaws.com" ]
    }
  }
}

data "aws_iam_policy_document" "jump-role-policy-document" {
  statement {
    effect    = "Allow"
    actions   = [
      "iam:GetSSHPublicKey",
      "iam:ListSSHPublicKeys",
      "iam:ListUsers",
      "iam:SimulatePrincipalPolicy",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ec2:DescribeInstances"
    ]      
    resources = [ "*" ]
  }
}

resource "aws_iam_role" "jump-role" {
  name               = "${var.context}-jump-role"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.jump-assume-role-policy-document.json}"
}

resource "aws_iam_instance_profile" "jump-profile" {
  name  = "${var.context}-jump-instance-profile"
  role = "${aws_iam_role.jump-role.name}"
}

resource "aws_iam_role_policy" "jump-role-policy" {
  name   = "${var.context}-jump-policy"
  role   = "${aws_iam_role.jump-role.id}"
  policy = "${data.aws_iam_policy_document.jump-role-policy-document.json}"
}

data "aws_ami" "amazon-linux" {
  owners = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-*-x86_64-gp2"]
  }
}

resource "aws_launch_configuration" "jump-lc" {
  name_prefix     = "lc-${var.context}-jump-"
  image_id        = "${data.aws_ami.amazon-linux.id}"
  instance_type   = "${var.jumphost_instance_type}"
  security_groups = [ "${aws_security_group.jump-sg.id}" ]
  user_data       = "${data.template_file.user-data.rendered}"
  key_name        = "${aws_key_pair.jump-key.key_name}"

  # Minimize downtime by creating a new launch config before destroying old one
  lifecycle {
    create_before_destroy = true
  }

  iam_instance_profile = "${aws_iam_instance_profile.jump-profile.id}"
}

resource "aws_security_group" "jump-elb-sg" {
  name        = "elb-${var.context}-jump"
  description = "Jump host load-balancer security group"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.cidr_whitelist}"]
  }
  
  egress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "elb-${var.context}-jump"
    Context = "${var.context}"
  }
}

resource "aws_elb" "jump-elb" {
  name            = "elb-${var.context}-jump"
  subnets         = ["${list(aws_subnet.public-a.id, aws_subnet.public-b.id)}"]
  security_groups = ["${aws_security_group.jump-elb-sg.id}"]
  idle_timeout    = 330
  
  listener {
    instance_port     = 22
    instance_protocol = "tcp"
    lb_port           = 22
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 10
    target              = "TCP:22"
    interval            = 15
  }

  tags {
    Name    = "elb-${var.context}-jump"
    Context = "${var.context}"
  }
}

resource "aws_autoscaling_group" "jump-asg" {
  depends_on = ["aws_cloudwatch_log_group.foundry"]
  name                 = "asg-${var.context}-jump-${aws_launch_configuration.jump-lc.id}"
  max_size             = "${var.jumphost_instance_count_max}"
  min_size             = "${var.jumphost_instance_count_min}"
  desired_capacity     = "${var.jumphost_instance_count_desired}"
  launch_configuration = "${aws_launch_configuration.jump-lc.name}"
  min_elb_capacity     = 1
  vpc_zone_identifier  = [ "${list(aws_subnet.private-a.id, aws_subnet.private-b.id)}" ]
  load_balancers       = [ "${aws_elb.jump-elb.id}" ]
  enabled_metrics      = [ "GroupMinSize","GroupMaxSize","GroupDesiredCapacity","GroupInServiceInstances","GroupPendingInstances","GroupStandbyInstances","GroupTerminatingInstances","GroupTotalInstances"]
  
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.context}-jump"
    propagate_at_launch = true
  }

  tag {
    key                 = "Context"
    value               = "${var.context}"
    propagate_at_launch = true
  }
}

resource "aws_route53_record" "jump-dns" {
  zone_id   = "${var.zone_id}"
  name      = "jump"
  type      = "A"
  
  alias {
    name                   = "${aws_elb.jump-elb.dns_name}"
    zone_id                = "${aws_elb.jump-elb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_efs_file_system" "user_fs" {
  creation_token = "jump-efs-${var.context}"
  encrypted      = true

  tags {
    Name    = "jump-efs-${var.context}"
    Context = "${var.context}"
  }
}

resource "aws_security_group" "user_efs_sg" {
  name        = "${var.context}-jump-ec2-mount"
  description = "Allow EC2 instance to mount EFS target"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = ["${aws_security_group.jump-sg.id}"]
    cidr_blocks     = ["${list(aws_subnet.private-a.cidr_block, aws_subnet.private-b.cidr_block)}"]
  }

  tags {
    Name    = "${var.context}-jump-ec2-mount"
    Context = "${var.context}"
  }
}

resource "aws_efs_mount_target" "jump_fs_target" {
  count           = "2"
  file_system_id  = "${aws_efs_file_system.user_fs.id}"
  subnet_id       = "${element(local.subnets, count.index)}"
  security_groups = ["${aws_security_group.user_efs_sg.id}"]
}
