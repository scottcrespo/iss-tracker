# Poller — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Plain Python script, not a framework
The poller is a short-lived script that runs, does one thing, and exits. A framework would add unnecessary overhead with no benefit. The simplicity is intentional and maps cleanly to the Kubernetes CronJob primitive.

## Single Docker image with dedicated entrypoint
The poller has its own `Dockerfile` separate from the API. Both apps share a `requirements.txt` but are built as independent images. This makes Docker Compose service definitions unambiguous, Kubernetes manifests cleaner, and avoids `command` overrides to differentiate containers at runtime.

## Separate Dockerfile per app (not shared)
Initially considered a single Dockerfile with different CMD entrypoints for poller and API. Rejected because it complicates local Docker Compose setup (all services running simultaneously), creates ambiguity about which entrypoint is the "default", and makes CI build steps less explicit. Separate Dockerfiles are more readable and each image is fully self-contained.

## Configurable retry logic for fetch
`FETCH_MAX_RETRIES`, `FETCH_RETRY_DELAY_SECONDS`, and `FETCH_TIMEOUT_SECONDS` are all environment variables rather than hardcoded. The public ISS API is occasionally slow — configurable timeouts and retries avoids transient failures causing CronJob failures in Kubernetes without requiring a code change.

## while loop for retry (not for loop)
Retry logic uses a `while` loop over a `for` loop. Both are equivalent, but `while attempt < max_retries` reads more naturally as "keep trying until exhausted" for retry semantics.

## ConnectTimeout retries, HTTPError does not
`httpx.ConnectTimeout` is a transient network condition worth retrying. `httpx.HTTPError` (4xx/5xx responses) indicates a protocol-level problem that retrying is unlikely to fix — so it raises immediately. This distinction is intentional.

## Prometheus Pushgateway for observability
The poller is a short-lived CronJob — Prometheus cannot scrape it directly since it exits before a scrape interval. The Pushgateway pattern solves this: the poller pushes a `iss_poller_last_success_timestamp_seconds` metric after each successful run. An alert fires if this metric hasn't updated within the expected interval, providing visibility into CronJob health without long-running infrastructure.

Pushgateway is optional — the poller checks for `PUSHGATEWAY_URL` before pushing. This means it runs cleanly in local dev without a Pushgateway.

## init_db() as dedicated function
Database initialization is isolated in `init_db()` with explicit error handling for connection failures and missing tables. This gives clear, structured log output at startup rather than a raw boto3 traceback. Failing fast with a meaningful error is preferable to a cryptic failure when the first write is attempted.

## Non-root container user
The Dockerfile creates a dedicated `appuser` with no home directory and no login shell, and runs the container as that user. This reduces the blast radius of a container escape and keeps Trivy image scans clean (root-running containers are flagged as a HIGH finding).

## apt-get upgrade in Dockerfile
The Dockerfile runs `apt-get update && apt-get upgrade -y` before installing dependencies to ensure the base image has the latest OS-level security patches. The apt cache is removed afterwards (`rm -rf /var/lib/apt/lists/*`) to avoid bloating the image layer.

## Explicit COPY instead of COPY . .
Only the files the poller needs are copied into the image (`poller.py`, `modules/`). Using `COPY . .` would include test files, `.env`, and other development artifacts — increasing image size and surface area. Explicit COPY keeps the production image minimal.

## poller/ as self-contained app directory
The poller was moved from a shared `apps/` directory into its own `apps/poller/` subdirectory with its own `Dockerfile`, `requirements.txt`, and `.env`. This makes the Docker build context clean, CI path filtering unambiguous, and each app fully self-contained.