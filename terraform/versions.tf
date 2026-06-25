terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Credentials are read from the environment, never committed:
#   - DIGITALOCEAN_ACCESS_TOKEN   (Droplets, firewall, SSH keys)
#   - SPACES_ACCESS_KEY_ID        (Spaces bucket + objects)
#   - SPACES_SECRET_ACCESS_KEY
# The Spaces key is created out-of-band (scripts/00-spaces-key.sh) and the
# resulting access-key/secret are passed in via the SPACES_* env vars.
provider "digitalocean" {}
