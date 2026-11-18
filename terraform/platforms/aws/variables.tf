variable "name" {
  type        = string
  description = "Unique VM inventory name."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.name))
    error_message = "Use 3–21 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_version" {
  type        = string
  default     = null
  description = "OS release to boot; null preserves Ubuntu 26.04 for legacy inventory"
}

variable "os" {
  type        = string
  default     = "ubuntu"
  description = "Golden image OS tag; a key of platform.json os."
  validation {
    condition     = contains(keys(jsondecode(file("${path.module}/platform.json")).os), var.os)
    error_message = "The OS must be a key of platform.json os."
  }
}

variable "size" {
  type        = string
  default     = "S"
  description = "Platform-independent size; a key of sizes.json. Ignored when instance_type is set."
  validation {
    condition     = can(regex("^[A-Z]{1,4}$", var.size))
    error_message = "Size must be a sizes.json key such as XS, S, M or L."
  }
}

variable "instance_type" {
  type        = string
  default     = ""
  description = "Explicit EC2 instance type from the IDP advanced picker; overrides size."
  validation {
    condition     = can(regex("^$|^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like m7i.large."
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

variable "request_id" {
  type        = string
  default     = ""
  description = "VM incarnation; used to adopt resources after interrupted state writes."
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
