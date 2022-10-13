# Hale Platform WordPress Multisite 

## Installation

This launches a working Wordpress site that pulls in the Hale theme.
You can choose to launch the site in Docker or Kubernetes.

Currently only the Docker build works locally but for CloudPlatform
environments you can use the kubernetes build.

## Required

- Docker running (and kubernetes turned on if you are launching the site in k8s)
- Have [Dory proxy](https://github.com/FreedomBen/dory) running for local install so you have a domain `hale.docker`
  to work with.
- Install [Helm](https://helm.sh/docs) - `brew install helm`

## Nice to have

-   [Kubens and Kubectx - to switch between namespace & clusters](https://github.com/ahmetb/kubectx)
-   [Stern - logging and debugging](https://github.com/wercker/stern)
-   [JQ - processing JSON](https://stedolan.github.io/jq)
-   Modify your shell to alias `kubectl` to just `k` for less typing

## Kubernetes

### Launch instructions

You will need an `.env.local` file in the root of this project with all the
variables needed to run the app. Get this from Rob or Adam until we have
a proper place for it.

1. Run `dory up` to get dory running as you will need this to proxy the
   hale.docker domain locally which WP multisite needs.
2. Run `make build` to build all the Docker images you'll need locally for k8s to use.
3. Run `make deploylocal` to run the helm command which launches the site. 
3. If all is running, go to `http://hale.docker` in your browser. You will be greeted by a WP installation page.

## Docker

### Launch instructions

In terminal run `make launch`. For other commands see `makefile`.

### Setup the https certs (currently only setup for Docker not k8s)

1. Run `brew install mkcert` (if you don't have it)
2. Run `mkdir -r /nginx/certs` , to create a new /certs folder.
3. In the /certs folder run `mkcert wordpress-docker.test`
4. Go to your host file on your mac /etc/hosts and add the wordpress-docker.test domain name
5. In this root directory, run `make build`
6. Go to your browser at the URL wordpress-docker.test

