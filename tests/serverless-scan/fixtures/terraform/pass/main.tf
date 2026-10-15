# Serverless pass fixture (issue #183): own role, scoped policy, declared log
# group with retention, dead-letter queue, concurrency limit, encrypted
# environment, no secrets.
provider "aws" {
  region = "us-west-2"
}

resource "aws_kms_key" "env" {
  description = "lambda environment"
}

resource "aws_sqs_queue" "dlq" {
  name = "ingest-dlq"
}

resource "aws_iam_role" "ingest" {
  name = "ingest-fn"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "ingest" {
  name = "ingest-fn"
  role = aws_iam_role.ingest.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.dlq.arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.ingest.arn}:*" },
    ]
  })
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/ingest"
  retention_in_days = 30
}

resource "aws_lambda_function" "ingest" {
  function_name                  = "ingest"
  role                           = aws_iam_role.ingest.arn
  handler                        = "app.handler"
  runtime                        = "python3.12"
  filename                       = "dist/ingest.zip"
  reserved_concurrent_executions = 5
  kms_key_arn                    = aws_kms_key.env.arn

  environment {
    variables = { STAGE = "prod" }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.ingest.name
  }
}
