# SPQR demo

[![CI](https://github.com/Denchick/demo/actions/workflows/ci.yml/badge.svg)](https://github.com/Denchick/demo/actions/workflows/ci.yml)

A sharded PostgreSQL you can start with one command: an
[SPQR](https://github.com/pg-sharding/spqr) router in front of two PostgreSQL 16
shards, loaded with a small messenger database (500 users, 1,000 chats,
100,000 messages).

```
            psql :6432            admin console :7432
                 \                    /
                  +---- router ------+
                  |                  |
        shard1 (sh1) :5441     shard2 (sh2) :5442
        chat_id 501..1000      chat_id 1..500
```

The only requirement is Docker with the compose plugin. The router comes from
the public `pgsharding/spqr-router` image; nothing is built locally.

## Start

```bash
git clone https://github.com/Denchick/demo.git spqr-demo
cd spqr-demo
docker compose run --rm load
```

That starts both shards and the router, waits until they are healthy, creates
the sharding rules and the schema, and loads the data. It ends by printing how
many rows landed on each shard. Run it again at any time to reset the demo to
this state.

## Connect

```bash
docker compose run --rm psql     # SQL through the router
docker compose run --rm admin    # router admin console
```

Or with your own client; there is no password:

| What          | Connection                                            |
| ------------- | ----------------------------------------------------- |
| Router        | `psql "host=localhost port=6432 dbname=demo user=demo"` |
| Admin console | `psql "host=localhost port=7432 dbname=demo user=demo"` |
| Shard `sh1`   | `psql "host=localhost port=5441 dbname=demo user=demo"` |
| Shard `sh2`   | `psql "host=localhost port=5442 dbname=demo user=demo"` |

## Things to try

`chats`, `chat_members`, `messages` and `reactions` are sharded by `chat_id`.
`users`, `emoji` and `languages` are reference tables, copied in full to every
shard.

All of the queries below are in [`sql/queries.sql`](sql/queries.sql); run the
whole tour with `docker compose run --rm -T psql -f queries.sql`.

Start by asking the router to say where each statement goes:

```sql
SET __spqr__reply_notice TO true;
```

**One shard.** The sharding key is in `WHERE`, so only its owner is asked.
Chat 1 lives on `sh2`, chat 1000 on `sh1`:

```sql
SELECT message_id, author_id, body, sent_at
FROM messages WHERE chat_id = 1 ORDER BY message_id DESC LIMIT 5;

SELECT message_id, author_id, body, sent_at
FROM messages WHERE chat_id = 1000 ORDER BY message_id DESC LIMIT 5;
```

**Joins that stay on one shard.** `users` is a reference table and `reactions`
shares the sharding key with `messages`:

```sql
SELECT m.message_id, u.name AS author, m.body
FROM messages m JOIN users u ON u.user_id = m.author_id
WHERE m.chat_id = 7 ORDER BY m.message_id DESC LIMIT 5;

SELECT e.name AS reaction, count(*) AS times
FROM reactions r
JOIN messages m ON m.chat_id = r.chat_id AND m.message_id = r.message_id
JOIN emoji e ON e.emoji = r.emoji
WHERE r.chat_id = 3
GROUP BY e.name ORDER BY times DESC;
```

**All shards.** Without a sharding key you ask for a scatter query explicitly.
You get one row per shard: the router concatenates the answers and does not
re-aggregate them.

```sql
SELECT count(*) AS messages FROM messages /* __spqr__scatter_query: true */;

SELECT chat_id FROM chat_members WHERE user_id = 42 /* __spqr__scatter_query: true */;
```

**A named shard.**

```sql
SELECT count(*) FROM chats /* __spqr__execute_on: sh1 */;
```

**Writes** follow the same key:

```sql
BEGIN;
INSERT INTO messages (chat_id, message_id, author_id, body, sent_at)
VALUES (1000, 1000000, 42, 'Hello from the SPQR demo!', now());
UPDATE chats SET title = 'Renamed by the demo' WHERE chat_id = 1000;
SELECT c.title, m.body FROM chats c JOIN messages m ON m.chat_id = c.chat_id
WHERE c.chat_id = 1000 AND m.message_id = 1000000;
ROLLBACK;
```

**In the admin console** (`docker compose run --rm admin`):

```sql
SHOW shards;
SHOW distributions;
SHOW key_ranges;
SHOW relations;
SHOW reference_relations;
SHOW clients;
```

**Straight on a shard**, to see that the data really is split. The load is
deliberately skewed, the low chat ids are the busy ones:

```bash
docker compose exec shard1 psql -U demo -d demo -c 'SELECT min(chat_id), max(chat_id), count(*) FROM messages'
docker compose exec shard2 psql -U demo -d demo -c 'SELECT min(chat_id), max(chat_id), count(*) FROM messages'
```

## Drop and stop

```bash
docker compose run --rm drop    # remove the tables and the sharding rules, keep the cluster
docker compose run --rm load    # load again
docker compose down -v          # stop and delete everything
```

## Good to know

- The router keeps its routing metadata in memory (there is no coordinator or
  etcd here). If the router container restarts, run
  `docker compose run --rm load` again.
- Ports are published on `127.0.0.1` only, and authentication is switched off.
  This is a demo, do not expose it.
- If a port is taken, override it: `ROUTER_PORT=16432 docker compose run --rm load`
  (also `ADMIN_PORT`, `SHARD1_PORT`, `SHARD2_PORT`).
- The router image is pinned in `docker-compose.yml`. To try another build:
  `SPQR_IMAGE=pgsharding/spqr-router:nightly docker compose run --rm load`.
  The `latest` tag on Docker Hub dates from August 2026 and is not tested here.

## Where the SQL comes from

`sql/messenger.sql` is generated by [`cmd/demogen`](cmd/demogen/main.go), a
single-file Go program with no dependencies. The output depends only on
`-size`, so the same size always gives the same file.

```bash
go run ./cmd/demogen -size s > sql/messenger.sql
```

Sizes: `s` (1,000 chats, 500 users, 100,000 messages; the one committed here),
`m` (100,000 chats, 10 million messages) and `l` (1 million chats, 100 million
messages). No Go installed? Use Docker:

```bash
docker run --rm -v "$PWD:/work" -w /work golang:1.26-alpine \
  go run ./cmd/demogen -size s > sql/messenger.sql
```

The generator and `sql/drop.sql` are copied unchanged from
[pg-sharding/spqr#3247](https://github.com/pg-sharding/spqr/pull/3247)
(commit `237bbb1`). The lint step fails if `sql/messenger.sql` no longer
matches what the generator produces.

## Development

```bash
./scripts/lint.sh          # compose config, shellcheck, shfmt, yamllint, gofmt, go vet (all in Docker)
./scripts/lint.sh fix      # reformat the shell scripts
./scripts/smoke-test.sh    # end to end: load, verify, query tour, drop, load again
```

CI runs both on every push and pull request, and once a week against the
current `nightly` router image.
