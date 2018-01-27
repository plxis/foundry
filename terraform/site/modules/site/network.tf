# -----------------------------------------------------------------------------
# This configuration creates a VPC network in the provided region
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "${var.cidr_base}.0.0/20"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags {
    Name        = "vpc-${var.context}-${var.region}"
    Context     = "${var.context}"
  }
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------

# Availability Zone "A"
resource "aws_subnet" "private-a" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${var.cidr_base}.3.0/24"
  availability_zone = "${var.availability_zones["a"]}"
  
  tags {
    Name        = "${var.context}-private-a"
    Context     = "${var.context}"
  }
}

resource "aws_subnet" "public-a" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${var.cidr_base}.4.0/24"
  availability_zone = "${var.availability_zones["a"]}"
  map_public_ip_on_launch = true
  tags {
    Name        = "${var.context}-public-a"
    Context     = "${var.context}"
  }
}

# Availability Zone "B"
resource "aws_subnet" "private-b" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${var.cidr_base}.5.0/24"
  availability_zone = "${var.availability_zones["b"]}"
  tags {
    Name        = "${var.context}-private-b"
    Context     = "${var.context}"
  }
}

resource "aws_subnet" "public-b" {
  vpc_id            = "${aws_vpc.main.id}"
  cidr_block        = "${var.cidr_base}.6.0/24"
  availability_zone = "${var.availability_zones["b"]}"
  map_public_ip_on_launch = true
  tags {
    Name        = "${var.context}-public-b"
    Context     = "${var.context}"
  }
}

# -----------------------------------------------------------------------------
# Routing
# -----------------------------------------------------------------------------
resource "aws_eip" "eip" {
  vpc = true
}

resource "aws_internet_gateway" "internet-gw" {
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name        = "internet-gw-${var.context}"
    Context     = "${var.context}"
  }
}

resource "aws_nat_gateway" "nat-gw" {
  depends_on    = [ "aws_internet_gateway.internet-gw" ]
  allocation_id = "${aws_eip.eip.id}"
  subnet_id     = "${aws_subnet.public-a.id}"
}

resource "aws_route_table" "route-tbl-private" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.nat-gw.id}"
  }

  tags {
    Name        = "route-tbl-private-${var.context}"
    Context     = "${var.context}"
  }
}

resource "aws_route_table" "route-tbl-public" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.internet-gw.id}"
  }
  
  tags {
    Name        = "route-tbl-public-${var.context}"
    Context     = "${var.context}"
  }
}

resource "aws_vpc_endpoint" "vpce-s3-private" {
    vpc_id = "${aws_vpc.main.id}"
    service_name = "com.amazonaws.us-east-1.s3"
    route_table_ids = ["${aws_route_table.route-tbl-private.id}","${aws_route_table.route-tbl-public.id}"]    
}

resource "aws_route_table_association" "public-a" {
  subnet_id = "${aws_subnet.public-a.id}"
  route_table_id = "${aws_route_table.route-tbl-public.id}"
}

resource "aws_route_table_association" "private-a" {
  subnet_id = "${aws_subnet.private-a.id}"
  route_table_id = "${aws_route_table.route-tbl-private.id}"
}

resource "aws_route_table_association" "private-b" {
  subnet_id = "${aws_subnet.private-b.id}"
  route_table_id = "${aws_route_table.route-tbl-private.id}"
}

resource "aws_route_table_association" "public-b" {
  subnet_id = "${aws_subnet.public-b.id}"
  route_table_id = "${aws_route_table.route-tbl-public.id}"
}
