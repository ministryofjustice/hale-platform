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
a proper place for it

1. Run `dory up` to get dory running as you will need this to proxy the
   hale.docker domain locally which WP multisite needs.
2. Run `make build` to build all the Docker images you'll need locally for k8s to use.
3. Run `make deploylocal` to run the helm command which launches the site. 
3. If all is running, go to `http://hale.docker` in your browser. You will be greeted by a WP installation page.

### Docker
Make sure you have the `.env.local` file with correct .env vars in the root of 
this repository

1. Create and install local TLS certs so the site runs on https.
2. Run `Dory up` from within this repository.
3. Run `make build`. This builds the images required and all assets.
4. Run `make run` to launch the site on https://hale.docker

## Create and install TLS certs (currently only setup for Docker not k8s)

1. Run `brew install mkcert` to install the mkcert app.
2. Run `mkdir -r /bin/certs` in the root of this repository, to create a new /certs folder in the bin/ directory.
3. In the /certs folder run `mkcert hale.docker` to create the certificates.
4. Run `mkcert -install` to apply certificates to your mac.
5. Make sure Dory is running `Dory up`.
6. Run `Make build`, to build the image and pull in the new cert pem files.
7. Go to your browser at the URL https://hale.docker

## Themes and Plugins.

WordPress themes and plugins are loaded as part of the Docker image build. They
are pulled into the build using PHP's Composer dependancy manager. To add or
remove plugins, modify the composer.json file in the root of this directory.

## Deployment
Our deployment pipeline uses GitActions to deploy to our various environments.

Hale platform can be deployed to 4 environments:
- Demonstration
- Development
- Staging
- Production

### Demonstration

The Demo environment is for showcases features and site functions to
stakeholders. A commit to the `demo` branch will trigger a build of the site to
the demostration environment. 

### Development

The Dev environment is for developers. This can be used for testing and
trailing features and functions in a CloudPlatform environment. A commit to the
`dev` branch will trigger a build in the development environment.

### Staging

The Staging environment is the preprod environment, used to test code
deployments before they reach production. A commit to the `main` branch will
trigger a build to the staging environment.

### Production

The Prod environment is the live environment for the multisite. Once a code
change has been tested on staging, you can trigger the build to move from
staging to production via the `Review deployments` button on the GitAction run
page. If you don't have a review deployments button you may not have the
correct permissions to deploy to production.

## DB Import/Export

This has to be done in steps.

First step, setup a pod in your k8s namespace. Use the following kubectl
command (delete pod after you're done using):

```
kubectl \                                                                                                                :dev
  -n <add namespace> \
  run port-forward-pod \
  --image=ministryofjustice/port-forward \
  --port=5432 \
  --env="REMOTE_HOST=<add in cloudplatform remote host aws address - port not needed>" \
  --env="LOCAL_PORT=5432" \
  --env="REMOTE_PORT=3306"
```

Second, step, setup port-forwarding pod with the following command:

```
kubectl \                                                                                                                :dev
  -n hale-platform-dev \
  port-forward \
  port-forward-pod 5432:5432
```

Third, once portforwarding is running, in a new tab, you can import and export using the
scripts db-import.sh and db-export.sh in the /bin directory. They will ask
for the db secrets, which you will need to get via the CloudPlatform brew
tool. 

Note: to import you will need to have the `mysql` & `mysqldump` program installed running on your local
machine

### Connect using MySQL Pro

Using the CloudPlatform secrets tool, fill in the fields as following:

Host: 127.0.0.1
Username: <db username>
Password: <db password>
Database: <db database name>
Port: 5432

