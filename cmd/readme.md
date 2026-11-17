# Development

Run the commands from the repository root.

## Generate the SQL dumps

The generator is a single Go program with no external dependencies. It writes
the sharding rules, schema, and data as a deterministic SQL script for each
size. [Generator source](demogen/main.go).

| Dump | Generator flag | Users | Chats | Messages |
| --- | --- | ---: | ---: | ---: |
| `messenger-small.sql.gz` | `s` | 500 | 1,000 | 100,000 |
| `messenger-medium.sql.gz` | `m` | 50,000 | 100,000 | 10,000,000 |
| `messenger-big.sql.gz` | `l` | 500,000 | 1,000,000 | 100,000,000 |
| `messenger-huge.sql.gz` | `huge` (temporary build) | 5,000,000 | 10,000,000 | 1,000,000,000 |

The Compose `load` service uses the checked-in, uncompressed small dump.
[Default dump](../sql/messenger.sql).

### Small, medium, and big

Build the generator once and stream its output through `gzip`. The `.gitignore`
in `dumps/` keeps the archives local.

```bash
set -o pipefail
work_dir=$(mktemp -d)
mkdir -p dumps
printf '*\n' > dumps/.gitignore
go build -o "$work_dir/demogen" ./cmd/demogen

write_dump() {
  local target="dumps/messenger-$1.sql.gz" partial
  shift
  partial=$(mktemp "$target.XXXXXX") || return
  if "$@" | gzip -1 -n > "$partial"; then
    mv "$partial" "$target"
  else
    rm -f "$partial"
    return 1
  fi
}

write_dump small "$work_dir/demogen" -size s
write_dump medium "$work_dir/demogen" -size m
write_dump big "$work_dir/demogen" -size l
```

Check the small archive against the committed SQL.

```bash
gzip -cd dumps/messenger-small.sql.gz | cmp - sql/messenger.sql
```

To regenerate the checked-in SQL, run `go run ./cmd/demogen -size s > sql/messenger.sql`.
With Docker, use the Go image from the lint script.

```bash
docker run --rm -v "$PWD:/work" -w /work golang:1.26-alpine \
  go run ./cmd/demogen -size s > sql/messenger.sql
```

### Huge

Use the same shell and make a temporary copy of the generator.

```bash
cp cmd/demogen/main.go "$work_dir/main.go"
```

In that copy, import `math/bits` and add an entry to the `sizes` map.

```go
"huge": {10_000_000, 5_000_000, 1_000_000_000},
```

In `messageCounts`, replace `upTo := cum * s.messages / total` with the
following two lines. At this size the product exceeds `uint64`, so the
calculation uses the full 128-bit product before dividing.

```go
hi, lo := bits.Mul64(cum, s.messages)
upTo, _ := bits.Div64(hi, lo, total)
```

Build the temporary copy and stream the dump to an archive of about 16 GiB.

```bash
go build -o "$work_dir/demogen-huge" "$work_dir/main.go" &&
  write_dump huge "$work_dir/demogen-huge" -size huge &&
  rm -r "$work_dir"
```

The local `huge` archive was generated in parallel by table and ID range.
The `messages` and `reactions` tables each used 16 chat-ID ranges balanced by
message count. Each part was compressed and checked before the gzip members
were concatenated in SQL order. The sequential recipe above reproduces the SQL.

## Checks

The lint script checks Compose, shell scripts, YAML, and Go. It also regenerates
the small SQL dump and compares it byte for byte with `sql/messenger.sql`. The
smoke test exercises loading, queries, dropping, and reloading.

```bash
./scripts/lint.sh
./scripts/lint.sh fix      # reformat shell scripts
./scripts/smoke-test.sh
```

CI runs both checks on pushes to `main`, pull requests, and a weekly schedule.
The smoke test runs against the pinned router image and the nightly image.
[CI workflow](../.github/workflows/ci.yml).

## Source

The generator and `sql/drop.sql` were copied from commit `237bbb1`.
[pg-sharding/spqr#3247](https://github.com/pg-sharding/spqr/pull/3247).
