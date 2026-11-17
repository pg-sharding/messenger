-- A short tour of the messenger demo. Run it through the router:
--
--   docker compose run --rm -T psql -f queries.sql
--
-- or paste the statements one by one into `docker compose run --rm psql`.
--
-- chats, chat_members, messages and reactions are sharded by chat_id:
--   chat_id   1..500  -> sh2
--   chat_id 501..1000 -> sh1
-- users, emoji and languages are reference tables: a full copy on every shard.

\set ON_ERROR_STOP on

-- Make the router say where each statement went.
SET __spqr__reply_notice TO true;

\echo
\echo '--- 1. Single-shard read: the sharding key is in WHERE, one shard answers'
SELECT message_id, author_id, body, sent_at
FROM messages
WHERE chat_id = 1
ORDER BY message_id DESC
LIMIT 5;

\echo
\echo '--- 2. Same query, another chat, the other shard'
SELECT message_id, author_id, body, sent_at
FROM messages
WHERE chat_id = 1000
ORDER BY message_id DESC
LIMIT 5;

\echo
\echo '--- 3. Join with a reference table: users is on every shard, so the join stays local'
SELECT m.message_id, u.name AS author, m.body
FROM messages m
JOIN users u ON u.user_id = m.author_id
WHERE m.chat_id = 7
ORDER BY m.message_id DESC
LIMIT 5;

\echo
\echo '--- 4. Join of two sharded tables on the same key: still one shard'
SELECT e.name AS reaction, count(*) AS times
FROM reactions r
JOIN messages m ON m.chat_id = r.chat_id AND m.message_id = r.message_id
JOIN emoji e ON e.emoji = r.emoji
WHERE r.chat_id = 3
GROUP BY e.name
ORDER BY times DESC;

\echo
\echo '--- 5. No sharding key: ask every shard. Each shard answers separately,'
\echo '---    the router concatenates the rows and does not re-aggregate them.'
SELECT count(*) AS messages FROM messages /* __spqr__scatter_query: true */;

\echo
\echo '--- 6. Scatter lookup by a non-key column: which chats is user 42 in?'
SELECT chat_id FROM chat_members WHERE user_id = 42 /* __spqr__scatter_query: true */;

\echo
\echo '--- 7. Pin a statement to one shard by name'
SELECT count(*) AS chats_on_sh1 FROM chats /* __spqr__execute_on: sh1 */;

\echo
\echo '--- 8. Writes are routed by the same key. Rolled back, so the demo stays intact.'
BEGIN;
INSERT INTO messages (chat_id, message_id, author_id, body, sent_at)
VALUES (1000, 1000000, 42, 'Hello from the SPQR demo!', now());
UPDATE chats SET title = 'Renamed by the demo' WHERE chat_id = 1000;
SELECT c.title, m.body
FROM chats c
JOIN messages m ON m.chat_id = c.chat_id
WHERE c.chat_id = 1000 AND m.message_id = 1000000;
ROLLBACK;

\echo
\echo '--- 9. EXPLAIN is passed through to the shard that owns the key'
EXPLAIN SELECT * FROM messages WHERE chat_id = 1;
