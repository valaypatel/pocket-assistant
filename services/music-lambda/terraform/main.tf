# Bearer key the app sends. Generated here so nothing has to be typed or pasted
# into a shell. It is kept in Terraform state, so keep the state private.
resource "random_password" "service_key" {
  length  = 48
  special = false
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "function" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Logs only. The function has no S3, database or other access, so it cannot
# keep audio anywhere.
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.function.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "music" {
  function_name = var.name
  role          = aws_iam_role.function.arn
  runtime       = "python3.12" # ShazamIO needs audioop, removed in Python 3.13
  handler       = "handler.lambda_handler"
  architectures = ["x86_64"]
  memory_size   = 1024
  timeout       = 30

  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)

  environment {
    variables = {
      SERVICE_KEY     = random_password.service_key.result
      MAX_AUDIO_BYTES = tostring(var.max_audio_bytes)
      # Optional: lets the service find the exact Spotify track. Empty disables it.
      SPOTIFY_CLIENT_ID     = var.spotify_client_id
      SPOTIFY_CLIENT_SECRET = var.spotify_client_secret
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.function,
    aws_iam_role_policy_attachment.logs,
  ]
}

# Public HTTPS address, protected by the bearer key the handler checks.
resource "aws_lambda_function_url" "music" {
  function_name      = aws_lambda_function.music.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = [var.allowed_origin]
    allow_methods = ["GET", "POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 600
  }
}

# A public Function URL needs both of these permissions.
resource "aws_lambda_permission" "url_invoke_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.music.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_function" {
  statement_id             = "AllowPublicFunctionUrlInvoke"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.music.function_name
  principal                = "*"
  invoked_via_function_url = true
}
