# SPQR demo

An SPQR router in front of two PostgreSQL 16 shards, loaded with a messenger
database of 500 users, 1,000 chats, and 100,000 messages.

## 1. Start the demo

With Docker Compose installed, run this from the repository root.

```bash
docker compose run --rm load
```

The command starts the router and both shards and loads the sample data. Running
it again resets the demo data.

## 2. Connect through the router

```bash
docker compose run --rm psql
```

To use your own SQL client, connect to `127.0.0.1:6432` with database `demo`,
user `demo`, and no password.

## 3. Try the queries

The `chats`, `chat_members`, `messages`, and `reactions` tables are sharded by
`chat_id`. Each shard has a copy of `users`, `emoji`, and `languages`.

Run the query tour from your terminal. [SQL examples](sql/queries.sql).

```bash
docker compose run --rm -T psql -f queries.sql
```

Enable notices in `psql` to see which shard handles each query.

```sql
SET __spqr__reply_notice TO true;
```

### Read from one shard

The router uses `chat_id` to send each query to the shard that owns it. Chat 1
is on `sh2` and chat 1000 is on `sh1`.

```sql
SELECT message_id, author_id, body, sent_at
FROM messages WHERE chat_id = 1 ORDER BY message_id DESC LIMIT 5;

SELECT message_id, author_id, body, sent_at
FROM messages WHERE chat_id = 1000 ORDER BY message_id DESC LIMIT 5;
```

### Join on one shard

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

### Query both shards

The scatter hint sends the query to both shards. The router concatenates the
results, so the count returns one row per shard.

```sql
SELECT count(*) AS messages FROM messages /* __spqr__scatter_query: true */;

SELECT chat_id FROM chat_members WHERE user_id = 42 /* __spqr__scatter_query: true */;
```

### Query a named shard

```sql
SELECT count(*) FROM chats /* __spqr__execute_on: sh1 */;
```

### Write and roll back

The sharding key routes the writes.

```sql
BEGIN;
INSERT INTO messages (chat_id, message_id, author_id, body, sent_at)
VALUES (1000, 1000000, 42, 'Hello from the SPQR demo!', now());
UPDATE chats SET title = 'Renamed by the demo' WHERE chat_id = 1000;
SELECT c.title, m.body FROM chats c JOIN messages m ON m.chat_id = c.chat_id
WHERE c.chat_id = 1000 AND m.message_id = 1000000;
ROLLBACK;
```

### Inspect the router configuration

Open the admin console from your terminal.

```bash
docker compose run --rm admin
```

```sql
SHOW shards;
SHOW distributions;
SHOW key_ranges;
SHOW relations;
SHOW reference_relations;
SHOW clients;
```

### Compare the data on each shard

Run these commands from your terminal to compare the chat ID ranges and
message counts.

```bash
docker compose exec shard1 psql -U demo -d demo -c 'SELECT min(chat_id), max(chat_id), count(*) FROM messages'
docker compose exec shard2 psql -U demo -d demo -c 'SELECT min(chat_id), max(chat_id), count(*) FROM messages'
```

[Development and dump generation](cmd/readme.md)
