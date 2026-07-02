variable "common_name" {
  description = "Short slug appended to every resource name. 3-8 lowercase alphanumeric chars."
  type        = string
  default     = "urlshort"

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.common_name))
    error_message = "common_name must be 3-8 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment slug used in resource names (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region for all course resources. Recorded against swedencentral."
  type        = string
  default     = "swedencentral"
}

variable "location_short" {
  description = "Short code for the Azure region, used in resource names. Must be set together with var.location."
  type        = string
  default     = "swc"
}

variable "image_owner" {
  description = "GHCR owner that publishes the urlshortener image. Override to point the Container App at your own build."
  type        = string
  default     = "lindbergtech"
}

variable "alert_email" {
  description = "Recipient for the Container App 5xx metric alert. Default is a clearly-fake placeholder so the alert exists end-to-end without spamming a real inbox; override to receive notifications."
  type        = string
  default     = "alerts-noreply@example.invalid"
}
