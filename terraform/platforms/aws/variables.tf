variable "name" {
  type        = string
  description = "Unique VM inventory name."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.name))
    error_message = "Use 3–21 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "os" {
  type        = string
  default     = "ubuntu"
  description = "Golden image OS tag."
  validation {
    condition     = contains(["ubuntu"], var.os)
    error_message = "Supported OS: ubuntu."
  }
}

variable "size" {
  type        = string
  default     = "S"
  description = "Platform-independent size."
  validation {
    condition     = contains(["S", "M", "L"], var.size)
    error_message = "Size must be S, M or L."
  }
}

variable "team" {
  type        = string
  default     = ""
  description = "Owning team, without entity-ref prefix."
}

variable "requested_by" {
  type        = string
  default     = ""
  description = "Initiating Backstage user."
}

variable "cloud_tags" {
  type        = map(string)
  default     = {}
  description = "Validated custom and informational billing tags from the VM spec."
  validation {
    condition     = alltrue([for key in keys(var.cloud_tags) : !startswith(lower(key), "cf:") && !startswith(lower(key), "aws:") && lower(key) != "name"])
    error_message = "Cloud tags cannot override Name or reserved cf:/aws: tags."
  }
}
