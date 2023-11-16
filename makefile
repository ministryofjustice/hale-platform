####################################################
### Local build config
####################################################

# Run site using Docker.
run:
	docker-compose up -d
	chmod +x bin/upload.sh
	./bin/upload.sh

# Shutdown site using Docker
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
