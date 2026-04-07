# API — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## DynamoDB over RDS/PostgreSQL
Chose DynamoDB instead of RDS to simplify infrastructure. No database subnet group, no RDS instance, no psycopg2 driver, no connection pooling. The ISS position data is a simple time-series write pattern that maps naturally to a single DynamoDB table. The trade-off is less query flexibility, but the API only needs two read patterns (latest record, N recent records) which DynamoDB handles well.

## Table design: pk="POSITION" + timestamp sort key
All records share the same partition key (`pk="POSITION"`) with a numeric Unix timestamp as the sort key. This means all records live in one partition and can be queried newest-first with `ScanIndexForward=False`. Simple and sufficient for this use case. Would not scale to high-volume write scenarios but is appropriate here.

## FastAPI lifespan handler for DB initialization
Used the `@asynccontextmanager` lifespan pattern (introduced in FastAPI 0.93) instead of the deprecated `@app.on_event("startup")`. 

**Execution flow:**
1. Python imports `api.py` — `app = FastAPI(lifespan=lifespan)` and `TABLE = None` are set at module level
2. uvicorn starts and triggers the lifespan handler before the app accepts any requests
3. `lifespan` calls `init_db()`, which creates the boto3 resource, calls `table.load()` to verify the table exists, and returns the table object
4. The returned table is assigned to the module-level `TABLE` variable via `global TABLE`
5. `yield` — app is now live and serving requests
6. On shutdown, any cleanup code after `yield` would run (none needed here)

**Why this matters for testing:** `TestClient` does not trigger the lifespan handler by default, so `TABLE` stays `None` during tests. Route handlers receive the mock table via `app.dependency_overrides` instead, meaning DB init code is never executed in the test environment.

## FastAPI dependency injection for table access
`get_table()` is declared as a FastAPI dependency and injected into route handlers via `Depends(get_table)`. The function simply returns the module-level `TABLE` object — no new connection is created per request.

**Why dependency injection over a module-level global:** Testability. In tests, `app.dependency_overrides[get_table] = lambda: mock_table` completely replaces the dependency without patching module internals. This is the idiomatic FastAPI testing pattern.

## Separate `init_db()` function
DB setup is isolated in `init_db()` rather than inlined into the lifespan handler. This keeps the lifespan handler readable and makes `init_db()` independently testable if needed.

`table.load()` is called explicitly to force a `DescribeTable` API call — boto3's `dynamodb.Table()` is lazy and does not verify the table exists until an operation is performed. Failing fast at startup with a clear error is preferable to a cryptic failure on the first request.

## 503 vs 404 for DynamoDB ClientError
Route handlers return 503 (Service Unavailable) for `ClientError` exceptions from DynamoDB, not 500. The distinction: 503 signals a temporary downstream dependency failure, which is more accurate and gives clients/load balancers a signal that retrying may succeed.

## limit cap at 100 for /positions
The `limit` query parameter on `/positions` is capped at 100 to prevent a single request from pulling an unbounded number of records. This is enforced in the handler rather than at the API schema level to keep the behavior explicit and easy to change.

## Unit testing approach

### TestClient + dependency_overrides
FastAPI's `TestClient` is used to make HTTP requests against the app in tests without running a real server. The DynamoDB table dependency is replaced via `app.dependency_overrides[get_table] = lambda: mock_table`, which injects a `MagicMock` into every route handler. This avoids any real AWS calls and keeps tests fully isolated.

`lambda: mock_table` is required because `dependency_overrides` expects a callable — it calls whatever you give it to resolve the dependency, the same way it would call `get_table()` in production.

### autouse fixture for mock reset
A `pytest.fixture(autouse=True)` resets the mock before every test to prevent state leakage between tests. Critically, `mock_table.query.side_effect = None` must be set explicitly before calling `reset_mock()` — `reset_mock()` alone does not clear `side_effect`, which caused a `ClientError` test to poison subsequent tests.

### Asserting on query arguments for limit cap test
The limit cap test (`test_read_positions_limit_cap_200`) uses `mock_table.query.assert_called_once_with(...)` to verify the handler passed `Limit=100` to DynamoDB when given `limit=105`. Simply asserting on response length would only test the mock's return value, not the handler's capping logic.

### ClientError construction in tests
`botocore.exceptions.ClientError` requires a specific dict shape: `{"Error": {"Code": "...", "Message": "..."}}` plus an operation name string. A bare exception instantiation won't work. Similarly, `httpx.HTTPError` requires a `request` attribute set manually after instantiation since it doesn't accept it as a constructor argument.

## uvicorn as the application server
FastAPI is an ASGI framework — it defines routes and handles request/response logic but does not serve HTTP connections itself. Uvicorn is the ASGI server that handles the network layer and calls into FastAPI. The CMD in the Dockerfile is `uvicorn api:app --host 0.0.0.0 --port 8000`, where `api:app` tells uvicorn to load the `app` object from `api.py`.

## Explicit COPY of api.py only
The Dockerfile copies only `api.py` into the image rather than the entire directory. This excludes test files, `.env`, and development artifacts from the production image.

## pytest excluded from production requirements
`pytest` and `pytest-cov` are installed separately in CI rather than being listed in `requirements.txt`. This keeps the production Docker image free of test tooling — the image should only contain what is needed to run the application.