####################################################
### Local build config
####################################################

.PHONY: run run-with-firewall run-with-pagecache down down-firewall down-pagecache build shell none clone-repos symlink logs restart clean help test-firewall
# Default target - list targets with their ## descriptions
help: ## Show this help
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  make %-22s - %s\n", $$1, $$2}'

# Run site using Docker
run: ## Start the Docker containers
	@echo "Starting Docker containers..."
	docker compose up -d
	@./bin/upload.sh
	@echo "✓ Site is running"

# Run site (start redis and enable firewall) using Docker
run-with-firewall: ## Run, with firewall config and dependencies
	@echo "Starting Docker containers..."
	FIREWALL_ENABLED=true docker compose --profile firewall up -d
	@./bin/upload.sh
	@echo "✓ Site is running"

# Run site (start redis and enable page cache, firewall stays off) using Docker
run-with-pagecache: ## Run, with page cache config and dependencies
	@echo "Starting Docker containers..."
	PAGECACHE_ENABLED=true docker compose --profile pagecache up -d
	@./bin/upload.sh
	@echo "✓ Site is running"

# Turn the firewall off: recreate the app containers with the flag unset
# (preserving the page cache flag), and only stop the shared Redis extras
# if the page cache isn't still using them.
down-firewall: ## Turn off the firewall, site keeps running
	@echo "Disabling firewall..."
	@PC=$$(docker inspect nginx --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^PAGECACHE_ENABLED=' | cut -d= -f2); \
	PC=$${PC:-false}; \
	FIREWALL_ENABLED=false PAGECACHE_ENABLED=$$PC docker compose --profile firewall --profile pagecache up -d nginx wordpress; \
	if [ "$$PC" = "true" ]; then \
		echo "Page cache still enabled - leaving Redis running"; \
	else \
		docker compose --profile firewall --profile pagecache stop redis redis-insight; \
	fi
	@echo "✓ Firewall disabled"

# Turn the page cache off: recreate the app containers with the flag unset
# (preserving the firewall flag), and only stop the shared Redis extras
# if the firewall isn't still using them.
down-pagecache: ## Turn off the page cache, site keeps running
	@echo "Disabling page cache..."
	@FW=$$(docker inspect nginx --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^FIREWALL_ENABLED=' | cut -d= -f2); \
	FW=$${FW:-false}; \
	PAGECACHE_ENABLED=false FIREWALL_ENABLED=$$FW docker compose --profile firewall --profile pagecache up -d nginx wordpress; \
	if [ "$$FW" = "true" ]; then \
		echo "Firewall still enabled - leaving Redis running"; \
	else \
		docker compose --profile firewall --profile pagecache stop redis redis-insight; \
	fi
	@echo "✓ Page cache disabled"

# Shutdown site using Docker
down: ## Stop and remove Docker containers
	@echo "Stopping Docker containers..."
	docker compose --profile firewall --profile pagecache down --remove-orphans
	@echo "✓ Containers stopped"

# Build all images on local machine
build: ## Build Docker images and install dependencies
	@echo "Building Docker images..."
	@./bin/local-build.sh

# Shell into the WordPress container
shell: ## Open bash shell in WordPress container
	@docker exec -it wordpress bash

# View logs from all containers
logs: ## View Docker container logs
	docker compose logs -f

# Restart all containers, preserving the firewall/page cache flags
# the running nginx container was started with (and their profiles).
restart: ## Restart all containers, keeping firewall/page cache state
	@FW=$$(docker inspect nginx --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^FIREWALL_ENABLED=' | cut -d= -f2); \
	PC=$$(docker inspect nginx --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^PAGECACHE_ENABLED=' | cut -d= -f2); \
	FW=$${FW:-false}; \
	PC=$${PC:-false}; \
	$(MAKE) down; \
	PROFILES=""; \
	if [ "$$FW" = "true" ]; then PROFILES="$$PROFILES --profile firewall"; fi; \
	if [ "$$PC" = "true" ]; then PROFILES="$$PROFILES --profile pagecache"; fi; \
	echo "Starting Docker containers..."; \
	FIREWALL_ENABLED=$$FW PAGECACHE_ENABLED=$$PC docker compose $$PROFILES up -d; \
	./bin/upload.sh; \
	echo "✓ Site is running"

# Clone all MoJ repositories
clone-repos: ## Clone all MoJ repositories into dev/ folder
	@echo "Cloning repositories..."
	@./bin/clone-repos.sh

# Create symlinks for dev packages inside container
symlink: ## Create symlinks for dev packages
	@echo "Creating symlinks for dev packages..."
	@docker exec wordpress bash /opt/scripts/link-dev-packages.sh
	@echo "✓ Symlinks created"

# Lint and test firewall scripts
test-firewall: ## Lint and test firewall scripts
	@echo "Linting and testing firewall scripts..."
	@./bin/local-test-firewall.sh

# Remove all dangling <none> images
none: clean ## Remove dangling <none> images (alias for clean)

# Clean up dangling images
clean: ## Remove dangling Docker images
	@echo "Removing dangling Docker images..."
	@docker image prune -f
	@echo "✓ Cleanup complete"
