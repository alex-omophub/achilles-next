#!/bin/sh
# Run only this isolated Compose project; keep data and evidence after failure.
set -eu
validationRoot=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
validationProject=${ACHILLESNEXT_VALIDATION_PROJECT:-achillesnext-validation}
case "$validationProject" in achillesnext-validation|achillesnext-validation-*) ;; *) echo 'Use an achillesnext-validation project prefix' >&2; exit 2;; esac
case "$validationProject" in *[!a-z0-9-]*) echo 'Invalid project characters' >&2; exit 2;; esac
[ "${#validationProject}" -le 63 ] || exit 2
export ACHILLESNEXT_VALIDATION_PROJECT="$validationProject"
export VALIDATION_UID="${VALIDATION_UID:-$(id -u)}" VALIDATION_GID="${VALIDATION_GID:-$(id -g)}"
case "$VALIDATION_UID:$VALIDATION_GID" in *[!0-9:]*) echo 'Numeric UID/GID required' >&2; exit 2;; esac
[ "$VALIDATION_UID" -gt 0 ] || { echo 'Select a non-root VALIDATION_UID/GID' >&2; exit 2; }
case "${ACHILLESNEXT_VALIDATION_OUTPUT:-}" in /*) ;; *) echo 'Set ACHILLESNEXT_VALIDATION_OUTPUT to an existing absolute directory' >&2; exit 2;; esac
validationOutput=$(CDPATH= cd -- "$ACHILLESNEXT_VALIDATION_OUTPUT" && pwd -P)
case "$validationOutput/" in "$validationRoot/"*) echo 'Output must be outside the checkout' >&2; exit 2;; esac
case "$validationRoot/" in "$validationOutput/"*) echo 'Output must not contain the checkout' >&2; exit 2;; esac
export ACHILLESNEXT_VALIDATION_OUTPUT="$validationOutput"
validationTag=${ACHILLESNEXT_VALIDATION_TAG:-local}
case "$validationTag" in ''|*[!a-zA-Z0-9_.-]*) echo 'Invalid validation image tag' >&2; exit 2;; esac
export ACHILLESNEXT_VALIDATION_IMAGE="achillesnext-validation:$validationTag"
compose() { docker compose --project-name "$validationProject" --file "$validationRoot/tools/docker/compose.yaml" "$@"; }
validationMode=${1:-smoke}
case "$validationMode" in
  build) compose build validator; exit;;
  status) compose ps --all; exit;;
  down) compose down; exit;;
  smoke|offline|telemetry) ;;
  *) echo 'Usage: validate.sh build|offline|smoke|telemetry|status|down' >&2; exit 2;;
esac
# Build inputs are cached; compose run never installs dependencies.
compose build validator
validationImageID=$(docker image inspect --format '{{.Id}}' "$ACHILLESNEXT_VALIDATION_IMAGE")
export ACHILLESNEXT_VALIDATION_IMAGE_ID="$validationImageID"
# Run the exact image just built, even if another build later moves its tag.
export ACHILLESNEXT_VALIDATION_IMAGE="$validationImageID"
compose run --rm --no-deps bootstrap
cleanup() {
  validationExit=$?
  trap - EXIT
  if ! compose stop --timeout 60 postgres >/dev/null 2>&1; then
    echo 'Could not stop this validation database; inspect the project status' >&2
    if [ "$validationExit" -eq 0 ]; then validationExit=1; fi
  fi
  exit "$validationExit"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
compose up --detach --wait --wait-timeout 120 postgres
compose run --rm --no-deps validator "$validationMode"
