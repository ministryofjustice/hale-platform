## Docker

# Run site using Docker.
run:
	docker-compose up

# Shutdown site using Docker.
down:
	docker-compose down

# Build all images on local machine
# and remove any previous WP installations.
# Without this docker build doesn't 
# overwrite already exiting folder and therefore
# doesn't update when bumping WP version for example.
build:
	chmod +x bin/build.sh && \
	./bin/build.sh

# Shell into the wordpress container
shell:
	docker exec -it wordpress bash

# Remove all dangling <none> images
none:
	docker rmi $(docker images -f "dangling=true" -q)

tagpush:
	docker tag hale-platform_wordpress 754256621582.dkr.ecr.eu-west-2.amazonaws.com/jotw-content-devs/hale-platform-dev-ecr:hale-platform_wordpress && \
	docker tag hale-platform_nginx 754256621582.dkr.ecr.eu-west-2.amazonaws.com/jotw-content-devs/hale-platform-dev-ecr:hale-platform_nginx && \
	docker push 754256621582.dkr.ecr.eu-west-2.amazonaws.com/jotw-content-devs/hale-platform-dev-ecr:hale-platform_wordpress && \
	docker push 754256621582.dkr.ecr.eu-west-2.amazonaws.com/jotw-content-devs/hale-platform-dev-ecr:hale-platform_nginx && \
	aws ecr list-images --repository-name jotw-content-devs/hale-platform-dev-ecr


deploylocal:
	chmod +x bin/deploy-local.sh && \
	./bin/deploy-local.sh

deploydev:
	chmod +x bin/deploy-dev.sh && \
	./bin/deploy-dev.sh

## AWS

# List all the images in ECR for our hale-platform-dev-ecr namespace
ecr-images:
	aws ecr list-images --repository-name jotw-content-devs/hale-platform-dev-ecr

# Run wp cli on the container
# Very handy little tool. TODO// make this
# more dynamic so you just have to add your
# wp cli commands
wpcli:
	docker-compose run --rm wp user list

# Kubernetes

# Setup the ConfigMap
# kubectl create configmap wpconfig --from-env-file=.env

# Build and run site in k8s cluster.
# kubectl apply manifests/

# Delete and shutdown site in k8s cluster.
# kubectl delete -k ./
