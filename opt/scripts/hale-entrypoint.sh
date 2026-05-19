#!/bin/bash
set -e
#set -o xtrace # Uncomment this line for debugging purposes

# Make a copy of docker-entrypoint and inject shell script into it so that our own config script can run
sed "$ i /usr/local/bin/config.sh" /usr/local/bin/docker-entrypoint.sh > /tmp/docker-entrypoint.sh

# WordPress's default docker-entrypoint.sh copies source code from /usr/src/wordpress to
# /var/www/html using tar. On K8s, /var/www/html is an emptyDir volume owned by root, and
# the container runs as non-root (UID 1002). When tar extracts, it tries to chmod the mount
# point directory "." to rwxrwxrwx, which fails with:
#   tar: .: Cannot change mode to rwxrwxrwx: Operation not permitted
# This causes the WordPress pod to error and restart once every time a pod is created.
# The files themselves extract fine — only the chmod on "." fails — so it is safe to ignore.
# This modification suppresses that specific tar error while still failing on any unexpected
# tar errors, preventing the unnecessary pod restart.
#
# The replacement pipeline:
#   - `{ ...; } 2>&1` groups the pipeline so stderr from BOTH tars is captured
#     into $tar_err (not just the target side). Upstream already sets
#     `set -Eeuo pipefail` at the top of docker-entrypoint.sh, so pipefail is
#     in effect for this pipeline and a source-tar failure will surface in $?.
#   - `|| tar_status=$?` captures a non-zero pipeline status instead of masking
#     it with `|| true`, so unknown failures can still fail startup.
IFS= read -r -d '' tar_pipeline_patch <<'PATCH' || true
		tar_status=0
		tar_err=$({ tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"; } 2>&1) || tar_status=$?
PATCH

# Fail startup if either:
#   - stderr contains anything other than the known-ignorable mount-point chmod
#     message (and tar's trailing "Exiting with failure" summary), or
#   - the pipeline exited non-zero but produced no stderr we can inspect
#     (a silent failure we shouldn't swallow).
#
# The ignorable lines are matched precisely so chmod failures against real
# extracted files (e.g. "tar: ./wp-admin/foo: Cannot change mode ...") still
# surface and fail the startup instead of being silently filtered out.
IFS= read -r -d '' tar_error_check <<'PATCH' || true
		filtered=$(echo "$tar_err" \
			| grep -vE '^tar: \.: Cannot change mode to [rwx-]{9}: Operation not permitted$' \
			| grep -vxF 'tar: Exiting with failure status due to previous errors' \
			|| true)
		if [ -n "$filtered" ] || { [ "$tar_status" -ne 0 ] && [ -z "$tar_err" ]; }; then
			echo "${tar_err:-tar failed with status $tar_status}" >&2
			exit 1
		fi
PATCH

# The exact line in WordPress's docker-entrypoint.sh we are replacing.
tar_pipeline_original='tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"'

# Replace the original tar pipeline with our patched version + error check.
# awk is used instead of sed because it handles multi-line replacements cleanly
# and has no magic characters (`&`, delimiters) to escape in the replacement text.
awk -v target="$tar_pipeline_original" \
    -v replacement="$tar_pipeline_patch"$'\n'"$tar_error_check" '
    index($0, target) { print replacement; next }
    { print }
' /tmp/docker-entrypoint.sh > /tmp/docker-entrypoint.sh.new \
    && mv /tmp/docker-entrypoint.sh.new /tmp/docker-entrypoint.sh

# Verify the tar patch was applied — if WordPress changes their entrypoint, we need to know
if ! grep -q 'tar_err=' /tmp/docker-entrypoint.sh; then
    echo >&2 "WARNING: tar permission patch was not applied to docker-entrypoint.sh — WordPress base image may have changed"
fi

# Execute the modified entrypoint from /tmp — deliberately NOT writing back to
# /usr/local/bin/ so the original stays pristine across container stop/start cycles.
chmod +x /tmp/docker-entrypoint.sh
exec /tmp/docker-entrypoint.sh "php-fpm"
