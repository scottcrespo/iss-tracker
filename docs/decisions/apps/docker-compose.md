# Docker Compose — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Single compose file at apps/docker-compose.yml
A single compose file covers all services (DynamoDB, init, poller, API, Pushgateway) rather than separate files per app. This enables full local integration testing — poller writes data, API reads it — with a single `docker compose up`. Individual services can still be started in isolation: `docker compose up dynamodb-local dynamodb-init api`.

## dynamodb-init as an init container pattern
A dedicated `dynamodb-init` service runs the `aws dynamodb create-table` command and exits before the poller or API start. Both depend on it with `condition: service_completed_successfully`. This avoids manual table creation steps and makes local setup fully automated. The AWS CLI image is reused for this purpose rather than writing a custom script.

## DynamoDB local port mapped to 8001, not 8000
`amazon/dynamodb-local` listens on port 8000 internally. This clashes with the API which also exposes 8000. The host-side mapping was changed to `8001:8000` for DynamoDB local. Inter-container communication still uses port 8000 via the service name (`http://dynamodb-local:8000`) — only the host-facing port changes.

## DynamoDB healthcheck using JVM check
`amazon/dynamodb-local` includes neither `curl` nor `wget`, making a real HTTP healthcheck impossible without adding tooling to the image. As a pragmatic workaround, the healthcheck verifies the JVM is running (`java -version`). This is acknowledged as a best-effort proxy — if Java is running, DynamoDB Local is almost certainly ready. This is irrelevant in production where AWS-managed DynamoDB is used.

## Separate .env per app
Each app (`poller/`, `api/`) has its own `.env` file referenced via `env_file` in the compose service definition. The compose `environment` block then overrides the localhost URLs with Docker service names (e.g. `DYNAMODB_ENDPOINT_URL: http://dynamodb-local:8000`). This keeps app-level config self-contained while allowing compose to inject the correct inter-container URLs at runtime.

## Pushgateway as optional service
The Pushgateway is included in compose but the poller only pushes metrics if `PUSHGATEWAY_URL` is set. This means the poller can run independently without the Pushgateway service being up — useful when only testing the fetch/write path without observability overhead.