# WordPress k8s build

## Installation (local)

This launches a working Wordpress site that pulls in the Hale theme (does not compile it yet).
You can choose to launch the site in Docker or Kubernetes.

## Required
* Docker running (and kubernetes turned on if you are launching the site in k8s)
* Uses localhost port 80 on your local machine. So if you have Dory (or anything else running on that) you'll need to turn that off.

## Nice to have
* [Kubens and Kubectx - to switch between namespace & clusters](https://github.com/ahmetb/kubectx)
* [Stern - logging and debugging](https://github.com/wercker/stern)
* [JQ - processing JSON](https://stedolan.github.io/jq)
* Modify your shell to alias `kubectl` to just `k` for less typing

## Kubernetes

### Launch instructions

1. Run `make build` to build all the Docker images you'll need locally for k8s to use.
2. Setup the config map by running `kubectl create configmap wpconfig --from-env-file=.env`
3. Run `kubectl apply -k manifests/`
4. Run `kubectl get pods` and make sure they are all 1/1, ie running.
5. If all is running, go to `http://localhost` in your browser. You will be greeted by a WP installation page.

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

### To Do

- namespaces not working right
- set Hale and plugins to default when sites loads.
- setup sync so that changes made to files reflect in the k8s cluster and local hosted site.
- Convert this standard WP install to a multisite using the WP Docker image variables
