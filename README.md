# Hale Platform WordPress Multisite 

## Installation

This launches a working Wordpress site that pulls in the Hale theme.
You can choose to launch the site in Docker or Kubernetes.

Currently only the Docker build works locally but for CloudPlatform
environments you can use the kubernetes build.

## Required

- [Docker](https://www.docker.com/) and kubernetes which can be turned on via the Docker-Desktop dashboard.
- Have [Dory proxy](https://github.com/FreedomBen/dory) running for local install so you have a domain `hale.docker`
  to work with.
- Install [Helm](https://helm.sh/docs) - `brew install helm`

## Nice to have

-   [Kubens and Kubectx - to switch between namespace & clusters](https://github.com/ahmetb/kubectx)
-   [Stern - logging and debugging](https://github.com/wercker/stern)
-   [JQ - processing JSON](https://stedolan.github.io/jq)

## Launch instructions

### Kubernetes

You will need an `.env.local` file in the root of this project with all the
variables needed to run the app. Get this from Rob or Adam until we have
a proper place for it.

1. Run `dory up` to get dory running as you will need this to proxy the
   hale.docker domain locally which WP multisite needs.
2. Run `make build` to build all the Docker images you'll need locally for k8s to use.
3. Run `make deploylocal` to run the helm command which launches the site. 
3. If all is running, go to `http://hale.docker` in your browser. You will be greeted by a WP installation page.

### Docker
Make sure you have the `.env.local` file with correct .env vars in the root of 
this repository.

1. Create and install local TLS certs so the site runs on https.
2. Run `Dory up` from within this repository.
3. Run `make build`. This builds the images required and all assets.
4. Run `make run` to launch the site on https://hale.docker

## Create and install TLS certs (currently only setup for Docker not k8s)

1. Run `brew install mkcert` to install the mkcert app.
2. Run `mkdir -r /bin/certs` in the root of this repository, to create a new /certs folder in the bin/ directory.
3. In the /certs folder run `mkcert hale.docker` to create the certificates.
4. Make sure Dory is running `Dory up`.
5. Run `Make build`, to build the image and pull in the new cert pem files.
6. Go to your browser at the URL https://hale.docker

## Themes and Plugins

WordPress themes and plugins are loaded as part of the Docker image build. They
are pulled into the build using PHP's Composer dependancy manager. To add or
remove plugins, modify the composer.json file in the root of this directory.
