####################################################
### Local build config
####################################################

.PHONY: run run-with-firewall run-with-pagecache down down-firewall down-pagecache build shell none clone-repos symlink logs restart clean help test-firewall wp-core-cve-check redis-cli redis-cli-local redis-cheatsheet uptime-run uptime-down
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

# Open a redis-cli shell against the cloud ElastiCache instance: scale up
# the redis-cli utility deployment (deployed by the wordpress chart with
# 0 replicas, wired to the hale-nginx-secrets secret), shell in with
# TLS + auth from the secret, then scale it back down on exit.
redis-cli: ## Open redis-cli against ElastiCache in current kubectl namespace
	@echo "Scaling up redis-cli pod in context $$(kubectl config current-context)..."; \
	kubectl scale deployment/redis-cli --replicas=1; \
	kubectl wait --for=condition=available deployment/redis-cli --timeout=90s; \
	$(MAKE) --no-print-directory redis-cheatsheet; \
	kubectl exec -it deployment/redis-cli -- \
		sh -c 'export REDISCLI_AUTH="$$REDIS_AUTH"; exec redis-cli -h "$$REDIS_HOST" --tls'; \
	echo "Scaling redis-cli back down..."; \
	kubectl scale deployment/redis-cli --replicas=0

# Open a redis-cli shell in the local docker compose redis container (no auth).
# Uses the compose service name so it works whatever the container is named.
redis-cli-local: redis-cheatsheet ## Open redis-cli against local Docker Redis
	@docker compose --profile firewall --profile pagecache exec redis redis-cli

# Print the redis-cli cheat sheet (shared by redis-cli and redis-cli-local)
redis-cheatsheet:
	@echo ""; \
	echo "=== General (db 0 = firewall, db 1 = page cache) ==="; \
	echo ""; \
	echo "  SELECT 1                                    - switch to page cache db"; \
	echo "  SELECT 0                                    - switch to firewall db"; \
	echo "  INFO keyspace                               - key count per db"; \
	echo "  DBSIZE                                      - total keys in current db"; \
	echo "  INFO stats                                  - hits/misses/evictions"; \
	echo ""; \
	echo "=== Page cache (SELECT 1 first) ==="; \
	echo ""; \
	echo "  GET pagecache:config                        - runtime mode {\"mode\":\"active|inactive\"}"; \
	echo "  GET pagecache:version                       - current cache version"; \
	echo "  SCAN 0 MATCH pagecache:* COUNT 100          - list cache keys (repeat with returned cursor)"; \
	echo "  TTL pagecache:v<ver>:<host>:<path>          - seconds left for a page"; \
	echo "  STRLEN pagecache:v<ver>:<host>:<path>       - cached page size in bytes"; \
	echo "  EXPIRE pagecache:v<ver>:<host>:<path> 1     - evict one page"; \
	echo ""; \
	echo "=== Firewall (SELECT 0 first) ==="; \
	echo ""; \
	echo "  SCAN 0 MATCH firewall:block:* COUNT 100     - per-IP blocks (firewall:allow:* for bypasses)"; \
	echo "  TTL firewall:block:<ip>                     - seconds left on a block"; \
	echo "  GET firewall:rules                          - rules JSON (also firewall:config,"; \
	echo "                                                firewall:allowlist, firewall:blocklist)"; \
	echo "  XREVRANGE firewall:audit + - COUNT 10       - last 10 audit events"; \
	echo ""

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

# Run the WordPress core version and CVE check locally.
# Prints findings and exits non-zero when it finds any. Posts nothing to Slack
# unless SKIP_SLACK=0. Needs a WPScan API token (https://wpscan.com/api).
wp-core-cve-check: ## Check WordPress core version and CVEs
	@./bin/wp-core-cve-check.sh

# Spin up the uptime monitor pod. It ships at zero replicas, and
# imagePullPolicy is Always, so scaling up always pulls the current image.
# Uses the current kubectl namespace context.
uptime-run: ## Spin up the uptime pod and run the monitor
	@echo "Starting uptime monitor"
	@kubectl scale deploy/uptime --replicas=1
	@kubectl rollout status deploy/uptime --timeout=2m
	@kubectl exec -it deploy/uptime -- uptime

# Scale back to zero when finished
uptime-down: ## Scale the uptime pod back to zero
	@echo "Stopping uptime monitor"
	@kubectl scale deploy/uptime --replicas=0
	@echo "✓ Uptime monitor stopped"

# Remove all dangling <none> images
none: clean ## Remove dangling <none> images (alias for clean)

# Clean up dangling images
clean: ## Remove dangling Docker images
	@echo "Removing dangling Docker images..."
	@docker image prune -f
	@echo "✓ Cleanup complete"
