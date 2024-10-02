####################################################
### Local build config
####################################################

# Run site using Docker.
run:
	docker compose up -d
	chmod +x bin/upload.sh
	./bin/upload.sh

# Shutdown site using Docker
down:
	docker compose down --remove-orphans

# Build all images on local machine
build:
	chmod +x bin/build.sh && \
	./bin/build.sh

# Shell into the wordpress container
shell:
	docker exec -it wordpress bash

# Remove all dangling <none> images
none:
	docker rmi $(docker images -f "dangling=true" -q)
