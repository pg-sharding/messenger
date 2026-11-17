#!/usr/bin/env bash
# Static checks: compose file, shell scripts, YAML, the Go generator.
# Needs only Docker.
#
#   ./scripts/lint.sh        check
#   ./scripts/lint.sh fix    reformat shell scripts in place

set -euo pipefail

cd "$(dirname "$0")/.."

in_docker() { docker run --rm -v "$PWD:/work" -w /work "$@"; }

if [[ ${1:-} == fix ]]; then
  in_docker mvdan/shfmt:v3 -w -i 2 -ci scripts
  exit
fi

echo '==> docker compose config'
docker compose config -q

echo '==> shellcheck'
in_docker koalaman/shellcheck:stable scripts/*.sh

echo '==> shfmt'
in_docker mvdan/shfmt:v3 -d -i 2 -ci scripts

echo '==> yamllint'
in_docker python:3-alpine sh -c \
  'pip install -q --root-user-action=ignore --disable-pip-version-check yamllint && yamllint .'

echo '==> gofmt, go vet, sql/messenger.sql is up to date'
# shellcheck disable=SC2016 # expanded inside the container, not here
in_docker golang:1.26-alpine sh -ec '
  test -z "$(gofmt -l cmd)" || { echo "gofmt needed:"; gofmt -l cmd; exit 1; }
  go vet ./...
  go run ./cmd/demogen -size s | cmp - sql/messenger.sql
'

echo 'Lint passed.'
