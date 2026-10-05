# Lets the GitHub Actions deploy workflow update this function's code, with no
# stored AWS keys: the job swaps its GitHub identity for short-lived credentials.
#
# The role can only touch this one function, and only a workflow running on the
# configured branch of the configured repository can assume it.

variable "github_repository" {
  description = "owner/name of the GitHub repository allowed to deploy. Empty creates no deploy role."
  type        = string
  default     = "valaypatel/pocket-assistant"
}

variable "github_deploy_ref" {
  description = "The git ref a workflow must be running on to deploy."
  type        = string
  default     = "refs/heads/main"
}

locals {
  deploy_enabled = var.github_repository != ""
}

# This account already has the GitHub provider (it is one per account, so it is
# looked up here rather than created).
data "aws_iam_openid_connect_provider" "github" {
  count = local.deploy_enabled ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_assume" {
  count = local.deploy_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:${var.github_deploy_ref}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  count              = local.deploy_enabled ? 1 : 0
  name               = "${var.name}-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume[0].json
}

data "aws_iam_policy_document" "deploy" {
  count = local.deploy_enabled ? 1 : 0

  # Update the code, wait for it to finish, and run the smoke test. Nothing else.
  statement {
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:InvokeFunction",
    ]
    resources = [aws_lambda_function.music.arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  count  = local.deploy_enabled ? 1 : 0
  name   = "update-${var.name}-code"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy[0].json
}
