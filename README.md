# Hale Platform

This repository has everything needed to run the Hale WordPress multisite platform on Kubernetes. The WordPress container is built on the Docker Hardened Image for WordPress (`dhi.io/wordpress`): a Debian-based image with no package manager, which runs as a non-root user (UID 65532). It is set up to run a multisite network, and Composer pulls in the themes and plugins the sites use. Test clear scope cache

Each pod runs three containers: `nginx`, which serves the site; `wordpress`, which runs PHP-FPM; and `wptools`, a sidecar with the database client.

For further technical details around the architecture, visit our wiki [overview](https://github.com/ministryofjustice/hale-platform/wiki).

## Deploy to a kubernetes environment

We use [Helm charts](https://github.com/ministryofjustice/hale-platform/tree/main/helm_deploy/wordpress) to manage our kubernetes manifest files. These are configured to work in the CloudPlatforms kubernetes environment but could be modified to work in any kubernetes cluster. This repo is used to deploy infrastructure changes (ie helm chart/kubernetes changes) and changes to the application, as it pulls in the latest version of the Hale theme and plugins.

To deploy, push to the branch for that environment: `dev`, `demo` or `main` (staging, then production). GitHub Actions builds the images and deploys them to the cluster.

More information about our deployment process, is available in our [Deployment](https://github.com/ministryofjustice/hale-platform/wiki/Deployment) wiki.

## Deploy locally on a Mac using Docker

To run this WordPress instance locally, follow our guidance on [local development](https://github.com/ministryofjustice/hale-platform/wiki/Local-development).

## Database commands

The WordPress image has no MySQL or MariaDB client, so `wp db` commands (query, export, import and the rest) fail in the `wordpress` container. Run them in the `wptools` container instead. Every other wp-cli command works in either.

```
# Kubernetes
kubectl exec <pod> -c wptools -- wp db query "SELECT 1"
kubectl exec <pod> -c wptools -- wp db export /scratch/dump.sql

# Locally
docker compose exec wptools wp db query "SELECT 1"
```

Save exports under `/scratch`, not the webroot (`/var/www/html`), where nginx could serve them. Both are deleted when the pod is replaced, so copy an export off straight away with `kubectl cp`.

