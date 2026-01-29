#!/bin/bash

# Get the script's directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed."
    echo ""
    echo "Please install it first:"
    echo ""
    echo "  macOS:   brew install gh"
    echo ""
    echo "After installation, authenticate with: gh auth login"
    exit 1
fi

# Check if user is authenticated
if ! gh auth status &> /dev/null; then
    echo "Error: You are not authenticated with GitHub CLI."
    echo ""
    echo "Please authenticate first by running:"
    echo "  gh auth login"
    echo ""
    exit 1
fi

# Define repositories by type
plugins=(
    "ministryofjustice/cookie-compliance"
    "ministryofjustice/website-builder-blocks"
    "ministryofjustice/wp-moj-blocks"
)

themes=(
    "ministryofjustice/govwind"
    "ministryofjustice/hale"
    "ministryofjustice/hale-dash"
    "ministryofjustice/hale-showcase"
    "ministryofjustice/ppo"
)

mu_plugins=(
    "ministryofjustice/hale-components"
    "ministryofjustice/wp-gov-uk-notify"
    "ministryofjustice/wp-s3-uploads"
)

# Create dev directories if they don't exist
mkdir -p "$PROJECT_ROOT/dev/plugins"
mkdir -p "$PROJECT_ROOT/dev/themes"
mkdir -p "$PROJECT_ROOT/dev/mu-plugins"

echo "Cloning Ministry of Justice repositories into dev/ folder..."
echo ""

# Clone plugins
echo "Cloning plugins..."
for repo in "${plugins[@]}"; do
    repo_name=$(basename "$repo")
    target_dir="$PROJECT_ROOT/dev/plugins/$repo_name"
    
    if [ -d "$target_dir" ]; then
        echo "$repo_name already exists, skipping..."
    else
        cd "$PROJECT_ROOT/dev/plugins"
        gh repo clone "$repo"
        if [ $? -eq 0 ]; then
            echo "  ✓ Successfully cloned $repo_name"
        else
            echo "  ✗ Failed to clone $repo_name"
        fi
    fi
done
echo ""

# Clone themes
echo "Cloning themes..."
for repo in "${themes[@]}"; do
    repo_name=$(basename "$repo")
    target_dir="$PROJECT_ROOT/dev/themes/$repo_name"
    
    if [ -d "$target_dir" ]; then
        echo "$repo_name already exists, skipping..."
    else
        cd "$PROJECT_ROOT/dev/themes"
        gh repo clone "$repo"
        if [ $? -eq 0 ]; then
            echo "  ✓ Successfully cloned $repo_name"
        else
            echo "  ✗ Failed to clone $repo_name"
        fi
    fi
done
echo ""

# Clone mu-plugins
echo "Cloning mu-plugins..."
for repo in "${mu_plugins[@]}"; do
    repo_name=$(basename "$repo")
    target_dir="$PROJECT_ROOT/dev/mu-plugins/$repo_name"
    
    if [ -d "$target_dir" ]; then
        echo "$repo_name already exists, skipping..."
    else
        cd "$PROJECT_ROOT/dev/mu-plugins"
        gh repo clone "$repo"
        if [ $? -eq 0 ]; then
            echo "  ✓ Successfully cloned $repo_name"
        else
            echo "  ✗ Failed to clone $repo_name"
        fi
    fi
done
echo ""

# Return to project root
cd "$PROJECT_ROOT"

echo "Done. All repositories cloned into dev/ folder."
echo ""
echo "Next steps:"
echo "  1. Run your build script to set up the project"
echo "  2. Symlinks will be created automatically to wordpress/wp-content/"
