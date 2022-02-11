# Docker

# Build and run site using Docker. Will run in background using -d flag.
launch:
	docker-compose up -d --build

# Run site using Docker.
run:
	docker-compose up

# Shutdown site using Docker.
down:
	docker-compose down

# Build all images on local machine
build:
	docker-compose build --no-cache

# Shell into the wordpress container
exec:
	docker exec -it wordpress bash


# Run wp cli on the container, for example:
# docker-compose run --rm wp user list

# Kubernetes

# Setup the ConfigMap
# kubectl create configmap wpconfig --from-env-file=.env

# Build and run site in k8s cluster.
# kubectl apply manifests/

# Delete and shutdown site in k8s cluster.
# kubectl delete -k ./
