variable "region" {
  description = "DigitalOcean region (must support Droplets and Spaces)."
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "Droplet size slug for each Mix-Proxy node."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "image" {
  description = "Droplet base image."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "node_count" {
  description = "Number of Mix-Proxy nodes. The MP network requires at least 4."
  type        = number
  default     = 4

  validation {
    condition     = var.node_count >= 4
    error_message = "The Mix-Proxy network must contain at least 4 nodes."
  }
}

variable "rs_node_count" {
  description = "Number of Regular Storage (RS) nodes to deploy."
  type        = number
  default     = 1
}

variable "rs_name_prefix" {
  description = "Prefix for Regular Storage droplet names."
  type        = string
  default     = "logos-rs"
}

variable "ssh_key_name" {
  description = "Name of an SSH key already registered in the DigitalOcean account. The matching private key must be usable unattended by Ansible (see ansible/ansible.cfg private_key_file)."
  type        = string
  default     = "giulianos-public-key-2"
}

variable "bucket_name" {
  description = "Spaces bucket name for published artifacts. Must be unique within the region endpoint (3-63 chars, lowercase/numbers/hyphens)."
  type        = string
  default     = "logos-storage-network"
}

variable "version_prefix" {
  description = "Path prefix (key namespace) for published objects within the bucket, e.g. v0.2 -> v0.2/mix-pool.json."
  type        = string
  default     = "v0.2"
}

variable "name_prefix" {
  description = "Prefix for droplet and firewall names."
  type        = string
  default     = "logos-mp"
}

variable "tags" {
  description = "Tags applied to all droplets."
  type        = list(string)
  default     = ["logos-storage", "mix-proxy", "v0_2"]
}

variable "artifacts_dir" {
  description = "Local directory (relative to the terraform module) where Ansible drops the merged artifacts to publish."
  type        = string
  default     = "../artifacts"
}
