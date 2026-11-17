#!/usr/bin/env bash
# End-to-end check of the demo: start the stack, load the data, verify it is
# sharded as documented, run the query tour, drop, and load again.
#
# Needs only Docker with the compose plugin. Leaves nothing behind unless
# KEEP=1 is set.

set -euo pipefail

cd "$(dirname "$0")/.."

compose() { docker compose "$@"; }

# SQL through the router / the admin console / straight on a shard.
router() { compose run --rm -T psql -v ON_ERROR_STOP=1 -qAt "$@"; }
admin() { compose run --rm -T admin -v ON_ERROR_STOP=1 -qAt "$@"; }
shard() {
  local n=$1
  shift
  compose exec -T "shard$n" psql -U demo -d demo -v ON_ERROR_STOP=1 -qAt "$@"
}

step() { printf '\n==> %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <what> <expected> <actual>
expect() {
  [[ $2 == "$3" ]] || fail "$1: expected '$2', got '$3'"
  printf 'ok: %s = %s\n' "$1" "$2"
}

cleanup() {
  local rc=$?
  if ((rc != 0)); then
    step "Failed (exit $rc), container logs follow"
    compose logs --no-color --tail 100 || true
  fi
  if [[ ${KEEP:-0} != 1 ]]; then
    compose --profile tools down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

check_loaded() {
  local s1 s2

  # Reference tables: a full copy on each shard.
  expect 'users on sh1' 500 "$(shard 1 -c 'SELECT count(*) FROM users')"
  expect 'users on sh2' 500 "$(shard 2 -c 'SELECT count(*) FROM users')"
  expect 'emoji on sh1' 8 "$(shard 1 -c 'SELECT count(*) FROM emoji')"
  expect 'emoji on sh2' 8 "$(shard 2 -c 'SELECT count(*) FROM emoji')"

  # Sharded tables: split by chat_id, nothing lost, nothing duplicated.
  expect 'chat_id range on sh1' '501-1000' \
    "$(shard 1 -c "SELECT min(chat_id) || '-' || max(chat_id) FROM chats")"
  expect 'chat_id range on sh2' '1-500' \
    "$(shard 2 -c "SELECT min(chat_id) || '-' || max(chat_id) FROM chats")"
  s1=$(shard 1 -c 'SELECT count(*) FROM messages')
  s2=$(shard 2 -c 'SELECT count(*) FROM messages')
  ((s1 > 0 && s2 > 0)) || fail "messages are not on both shards: sh1=$s1 sh2=$s2"
  expect 'messages on sh1 + sh2' 100000 "$((s1 + s2))"

  # The router agrees with the shards.
  expect 'messages in chat 1 via router' \
    "$(shard 2 -c 'SELECT count(*) FROM messages WHERE chat_id = 1')" \
    "$(router -c 'SELECT count(*) FROM messages WHERE chat_id = 1')"
  expect 'messages in chat 1000 via router' \
    "$(shard 1 -c 'SELECT count(*) FROM messages WHERE chat_id = 1000')" \
    "$(router -c 'SELECT count(*) FROM messages WHERE chat_id = 1000')"
  expect 'sharded relations in the router' 4 \
    "$(admin -c 'SHOW relations' | grep -c 'ds_chats')"
}

check_dropped() {
  local n
  for n in 1 2; do
    expect "tables left on sh$n" 0 \
      "$(shard "$n" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
  done
  expect 'sharded relations in the router' 0 \
    "$(admin -c 'SHOW relations' | grep -c 'ds_chats' || true)"
  expect 'key ranges in the router' 0 \
    "$(admin -c 'SHOW key_ranges' | grep -c 'ds_chats' || true)"
}

step 'Start the stack and load the demo'
compose run --rm -T load
check_loaded

step 'Run the query tour'
router -f queries.sql >/dev/null
check_loaded

step 'Drop'
compose run --rm -T drop >/dev/null
check_dropped

step 'Drop again (must be idempotent)'
compose run --rm -T drop >/dev/null
check_dropped

step 'Load again'
compose run --rm -T load >/dev/null
check_loaded

step 'Load over existing data (must reset, not fail)'
compose run --rm -T load >/dev/null
check_loaded

printf '\nAll checks passed.\n'
