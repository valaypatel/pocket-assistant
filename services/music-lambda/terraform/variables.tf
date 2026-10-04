variable "region" {
  description = "AWS region to deploy to."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. Leave null to use AWS_PROFILE or the default chain."
  type        = string
  default     = null
}

variable "name" {
  description = "Name used for the function, role and log group."
  type        = string
  default     = "circuit-music"
}

variable "zip_path" {
  description = "Package built by build.py."
  type        = string
  default     = "../build/music-lambda.zip"
}

variable "max_audio_bytes" {
  description = "Largest clip accepted. 12 s of 16 kHz mono 16-bit audio is about 384 KB."
  type        = number
  default     = 3145728
}

variable "log_retention_days" {
  description = "How long CloudWatch keeps the request logs (ids and outcomes only)."
  type        = number
  default     = 14
}

variable "allowed_origin" {
  description = <<-E
    Browser origin allowed by CORS. The Android app is not a browser and does not
    need CORS; this only stops other websites calling the URL from a browser.
  E
  type        = string
  default     = "https://localhost"
}
