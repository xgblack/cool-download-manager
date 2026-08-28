# Download Core Benchmark

`CoolDownloadBenchmark` runs the production `DownloadService` against a local,
streaming HTTP/1.1 Range source by default. The fixture binds only to
`127.0.0.1`, generates deterministic bytes without holding the whole file in
memory, and validates every completed output before reporting a run. An
external `http`/`https` URL can be supplied for CDN, HTTP/2 and proxy checks;
external runs verify the response length and can additionally verify SHA-256.

Use the complete Xcode toolchain recorded in `.helloagents/context.md`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift run --disable-sandbox CoolDownloadBenchmark \
  --size-mib 256 \
  --connections 1,2,4,8,16 \
  --repetitions 3 \
  --warmups 1 \
  --tasks 1 \
  --minimum-part-mib 16 \
  --output /tmp/cooldm-download-benchmark.json \
  > /tmp/cooldm-download-benchmark.stdout.json
```

To model a source that limits each HTTP stream to about 4 MiB/s:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift run --disable-sandbox CoolDownloadBenchmark \
  --size-mib 64 \
  --connections 1,2,4,8 \
  --repetitions 3 \
  --warmups 1 \
  --per-connection-mibps 4 \
  --output /tmp/cooldm-limited-source.json \
  > /tmp/cooldm-limited-source.stdout.json
```

To exercise the retry and low-FD paths with four concurrent tasks:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift run --disable-sandbox CoolDownloadBenchmark \
  --size-mib 256 \
  --connections 1,2,4,8 \
  --tasks 4 \
  --global-connections 8 \
  --max-open-fds 4 \
  --fail-first-data-requests 4 \
  --retry-attempts 3 \
  --retry-delay-ms 100 \
  --repetitions 3 \
  --warmups 1 \
  --output /tmp/cooldm-download-pressure.json \
  > /tmp/cooldm-download-pressure.stdout.json
```

`--max-open-fds` is a reservation budget, not a change to the process
`RLIMIT_NOFILE`. The service admits at most `floor(budget / 2)` active tasks so
each task can retain one part-file reservation and one request reservation. If
the budget is lowered while tasks are running, the newest excess tasks are
paused and can be resumed after the budget is raised.

Progress goes to stderr and the schema-versioned JSON report goes to stdout.
Results contain aggregate goodput, request and TTFB counts, failed-response and
retry counts, response-latency p95, checkpoint/fsync cost, checkpoint phase
timings (JSON encode/write/synchronize/replace for the record and, when a
legacy or existing compatibility sidecar is active, the sidecar),
CPU, peak RSS, peak FD count, kernel-accounted writes, observed server
concurrency, and content verification. The loopback fixture is suitable for repeatable regression
comparisons; it does not replace public CDN, HTTP/2, proxy, HDD, or
network-filesystem testing.

Every warmup and measured run executes in a fresh child process. This prevents
retained URLSession buffers and allocator high-water marks from making later
connection values appear to consume more memory merely because they ran later.

## External source and storage matrix

Use a public file or a staging CDN endpoint with a known size. Omit
`--size-mib` when the size is not known in advance; the completed response size
is then used for goodput. Add `--sha256` when an independent digest is
available:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
swift run --disable-sandbox CoolDownloadBenchmark \
  --url https://example.com/test-file.bin \
  --connections 1,2,4,8 \
  --repetitions 3 \
  --warmups 1 \
  --timeout-seconds 900 \
  --downloads-root /Volumes/test-ssd/cooldm-bench \
  --output /tmp/cooldm-public.json \
  > /tmp/cooldm-public.stdout.json
```

For an HTTP proxy, use `--proxy-url http://[user:password@]host:port` together
with `--url`. Proxy credentials and URL query parameters are removed from the
persisted report. `--keep-files` retains each isolated run directory under the
selected `--downloads-root`; otherwise it is removed after metrics and
verification are collected. A report with `schemaVersion: 4` has
`server: null` for external runs because the local fixture counters are not
available.

The benchmark does not force HTTP/1.1 or HTTP/2. `URLSession` negotiates the
protocol allowed by the endpoint and proxy. Record the endpoint/proxy setup
alongside the JSON when comparing protocol variants; the report intentionally
does not persist credentials or full URLs.
