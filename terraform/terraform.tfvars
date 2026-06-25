# Deployment parameters for the Logos Storage Mix-Proxy network.
# Credentials are NOT set here; they come from the environment (see scripts/env.sh).

region       = "fra1"
droplet_size = "s-8vcpu-16gb"
image        = "ubuntu-24-04-x64"
node_count   = 4
ssh_key_name = "giulianos-public-key"
bucket_name  = "logos-storage-network"
name_prefix  = "logos-mp"
