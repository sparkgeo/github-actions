resource "aws_security_group_rule" "egress" {
  cidr_blocks = ["10.0.0.0/8"]
}
