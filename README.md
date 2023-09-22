[![Hale Platform Deployment](https://github.com/ministryofjustice/hale-platform/actions/workflows/cd.yaml/badge.svg?branch=main)](https://github.com/ministryofjustice/hale-platform/actions/workflows/cd.yaml)

# Hale Platform WordPress Multisite

This repository provides all the code required to run an instance of WordPress multisite in kubernetes. It can be deployed to four environments (prod,staging,dev,demo). It also is possible to run this locally on a Mac using Docker. It uses the WordPress official Alpine image, modified to launch a multisite network and then uses PHP dependency manager Composer to pull in all the themes and plugins used by the multisite. For further technical details around the architecture, visit our wiki [overview](https://github.com/ministryofjustice/hale-platform/wiki).

## Deploy to a kubernetes environment

We use [Helm charts](https://github.com/ministryofjustice/hale-platform/tree/main/helm_deploy/wordpress) to manage our kubernetes manifest files. These are configured to work in the CloudPlatforms kubernetes environment but could be modified to work in any kubernetes cluster. This repo is used to deploy infrastructure changes (ie helm chart/kubernetes changes) and changes to the application, as it pulls in the latest version of the Hale theme and plugins.

To deploy to one of our environments, push a code change to one of the corresponding branches in this repo which will trigger GitActions that deploy the code into the kubernetes cluster.

More information about our deployment process, is available in our [Deployment](https://github.com/ministryofjustice/hale-platform/wiki/Deployment) wiki.

## Deploy locally on a Mac using Docker

To run this WordPress instance locally, follow our guidance on [local development](https://github.com/ministryofjustice/hale-platform/wiki/Local-development).
