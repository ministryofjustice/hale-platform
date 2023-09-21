# Hale Platform WordPress Multisite

This repository provides all the code required to run an instance of WordPress multisite in kubernetes. It can be deployed to four environments (prod,staging,dev,demo). It also is possible to run this locally on a Mac using Docker. It uses the WordPress official Alpine image, modified to launch a multisite network and then uses PHP dependency manager Composer to pull in all the themes and plugins used by the multisite. For further technical details around the architecture, visit our wiki [overview](https://github.com/ministryofjustice/hale-platform/wiki).

# Deploy to a kubernetes environment

We use [Helm charts](https://github.com/ministryofjustice/hale-platform/tree/main/helm_deploy/wordpress) to manage our kubernetes manifest files. These are configured to work in the CloudPlatforms kubernetes environment but could be modified to work in any kubernetes cluster.

As mentioned Hale platform can be deployed to 4 hosted environments:
- Demonstration
- Development
- Staging
- Production

To deploy out to the demo and dev environments, merge or push code changes to the `dev` or `demo` branch and this will automatically trigger GitActions to deploy the app into the corresponding kubernetes environment. To deploy to staging or production, push to the `main` branch first. This will deploy the code out to the `staging` environment where it can be reviewed. Once it is ready to deploy to production go into the GitActions section of GitHub and find the `Review deployments` button where you can approve deployment to production. You need to be added to the Hale Deployment team group to have permissions to deploy to prod.

More information is available in our [Deployment](https://github.com/ministryofjustice/hale-platform/wiki/Deployment) wiki.

# Deploy locally on a Mac using Docker

To run this WordPress instance locally, follow our guidance on [local development](https://github.com/ministryofjustice/hale-platform/wiki/Local-development).
