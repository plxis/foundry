resource "aws_ses_domain_identity" "ses_domain" {
  count = "${var.enabled == "true" ? 1 : 0}"
  domain = "${var.domain_name}"
}

resource "aws_route53_record" "amazonses_verification_record" {
  count = "${var.enabled == "true" ? 1 : 0}"
  zone_id = "${var.zone_id}"
  name    = "_amazonses.${var.domain_name}"
  type    = "TXT"
  ttl     = "600"
  records = ["${aws_ses_domain_identity.ses_domain.verification_token}"]
}

resource "aws_ses_domain_dkim" "dkim_generator" {
  count = "${var.enabled == "true" ? 1 : 0}"
  domain = "${aws_ses_domain_identity.ses_domain.domain}"
}

resource "aws_route53_record" "dkim_verification_record" {
  count   = "${var.enabled == "true" ? 3 : 0}"
  zone_id = "${var.zone_id}"
  name    = "${element(aws_ses_domain_dkim.dkim_generator.dkim_tokens, count.index)}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = "600"
  records = ["${element(aws_ses_domain_dkim.dkim_generator.dkim_tokens, count.index)}.dkim.amazonses.com"]
}