resource "aws_security_group_rule" "egress" {
  type        = "egress"
  cidr_blocks = ["240.1.0.0/16", "10.0.0.0/8", "0.0.0.0/0"]
}

resource "aws_route53_record" "cname" {
  name    = "api.internal.example.com"
  type    = "CNAME"
  records = ["c2.example"]
}
