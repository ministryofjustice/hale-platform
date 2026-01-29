####################################################
### Local build config
####################################################

.PHONY: run down build shell none clone-repos symlink logs restart clean help

# Default target - show help
help:
	@echo "Available commands:"
	@echo "  make run          - Start the Docker containers"
	@echo "  make down         - Stop and remove Docker containers"
	@echo "  make build        - Build Docker images and install dependencies"
	@echo "  make shell        - Open bash shell in WordPress container"
	@echo "  make logs         - View Docker container logs"
	@echo "  make restart      - Restart all containers"
	@echo "  make clone-repos  - Clone all MoJ repositories into dev/ folder"
	@echo "  make symlink      - Create symlinks for dev packages"
	@echo "  make clean        - Remove dangling Docker images"
	@echo "  make none         - Remove dangling <none> images (alias for clean)"

# Run site using Docker
run:
	@echo "Starting Docker containers..."
	docker compose up -d
	@chmod +x bin/upload.sh
	@./bin/upload.sh
	@echo "✓ Site is running"

# Shutdown site using Docker
down:
	@echo "Stopping Docker containers..."
	docker compose down --remove-orphans
	@echo "✓ Containers stopped"

# Build all images on local machine
build:
	@echo "Building Docker images..."
	@chmod +x bin/build.sh
	@./bin/build.sh

# Shell into the WordPress container
shell:
	@docker exec -it wordpress bash

# View logs from all containers
logs:
	docker compose logs -f

# Restart all containers
restart: down run

# Clone all MoJ repositories
clone-repos:
	@echo "Cloning repositories..."
	@chmod +x bin/clone-repos.sh
	@bash bin/clone-repos.sh

# Create symlinks for dev packages inside container
symlink:
	@echo "Creating symlinks for dev packages..."
	@docker exec wordpress bash /opt/scripts/link-dev-packages.sh
	@echo "✓ Symlinks created"

# Remove all dangling <none> images
none: clean

# Clean up dangling images
clean:
	@echo "Removing dangling Docker images..."
	@docker images -f "dangling=true" -q | xargs -r docker rmi || echo "No dangling images to remove"
	@echo "✓ Cleanup complete"
