# Serverless fail fixture (issue #183): role from a literal ARN (not
# declared here), wildcard policy on a declared role, log group without
# retention and not wired to the function, no DLQ, no concurrency limit, a
# secret in the environment, no CMK.
provider "aws" {
  region = "us-west-2"
}

resource "aws_iam_role" "shared" {
  name = "shared-fn"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "shared" {
  name = "shared-fn"
  role = aws_iam_role.shared.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["s3:*", "iam:PassRole"], Resource = "*" }]
  })
}

resource "aws_cloudwatch_log_group" "export" {
  name = "/aws/lambda/export"
}

resource "aws_lambda_function" "export" {
  function_name = "export"
  role          = "arn:aws:iam::123456789012:role/shared-fn"
  handler       = "app.handler"
  runtime       = "python3.12"
  filename      = "dist/export.zip"

  environment {
    variables = { API_KEY = "AKIAIOSFODNN7EXAMPLE" }
  }
}
