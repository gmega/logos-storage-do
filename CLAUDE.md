# Logos Storage Network - Temporary Deploy

You will help me deploy a Logos Storage Network to Digital Ocean.

* Background:

Logos storage is a filesharing network which runs as part of the platform. Storage nodes can serve, request, and replicate content for each other, like in BitTorrent.
The current incarnation of the network uses a Mix network to provide anonimity for queries.

I've put together instructions on how to deploy a network here: https://github.com/status-im/infra-logos/issues/25
I've also put together a reference harness for deploying a local network here: https://github.com/gmega/logos-storage-runner

You can also learn more about logos storage by going through its codebase:

* https://github.com/logos-storage/logos-storage-nim
* https://github.com/logos-co/logos-storage-module

What I want from you:

* I want you to deploy four mix-proxy nodes to Digital Ocean, using droplets. A droplet (VM) per node.
* I want you to manage the nodes using Terraform.
* I want you to provision them with Ansible.

* I want you to store the mix-pool.json file in a bucket, and make it available over a public URL.
* I want you to store the list of proxy TCP SPRs in a bucket, and make it available over a public URL.

Let's see how you fare with this info.