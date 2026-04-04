import os
import logging

import boto3
from botocore.exceptions import EndpointConnectionError, NoRegionError, ClientError
from boto3.dynamodb.conditions import Key
from fastapi import FastAPI, Depends, HTTPException
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    FastAPI lifespan handler. Runs once at application startup before the app
    begins serving requests. Initializes the DynamoDB table connection and
    stores it in the module-level TABLE variable.

    Args:
        app: The FastAPI application instance.
    """
    table_name = os.environ["DYNAMODB_TABLE"]
    endpoint_url = os.getenv("DYNAMODB_ENDPOINT_URL")
    global TABLE
    TABLE = init_db(table_name, endpoint_url)
    yield

# app context
app = FastAPI(lifespan=lifespan)
TABLE = None

def init_db(table_name: str, endpoint_url: str) -> object:
    """
    Creates a boto3 DynamoDB resource and returns a reference to the specified
    table. Calls table.load() to verify the table exists before returning.

    Args:
        table_name: Name of the DynamoDB table to connect to.
        endpoint_url: Optional DynamoDB endpoint URL. Used to point to
                      a local DynamoDB instance in development. Pass None
                      to use the default AWS endpoint in production.

    Returns:
        A boto3 DynamoDB Table resource object.

    Raises:
        EndpointConnectionError: If the DynamoDB endpoint cannot be reached.
        NoRegionError: If no AWS region is configured.
        ResourceNotFoundException: If the specified table does not exist.
    """
    try:
        dynamodb = boto3.resource("dynamodb", endpoint_url= endpoint_url)
    except (EndpointConnectionError, NoRegionError) as e:
        logger.error(f"Failed to connect to DynamoDB: {e}")
        raise

    try:
        table = dynamodb.Table(table_name)
        # load() forces a round-trip to verify the table exists
        table.load()
    except dynamodb.meta.client.exceptions.ResourceNotFoundException:
        logger.error(f"DynamoDB table '{table_name}' does not exist")
        raise  

    logger.info(f"Connected to DynamoDB table '{table_name}'")
    return table

def get_table() -> object:
    """
    FastAPI dependency that returns the module-level DynamoDB Table object.
    The table is initialized once at startup via the lifespan handler.
    In tests, this function is replaced via app.dependency_overrides.

    Returns:
        The boto3 DynamoDB Table resource object.
    """
    return TABLE

@app.get("/position")
def read_position(table=Depends(get_table)):
    """
    Returns the most recent ISS position recorded by the poller.

    Args:
        table: DynamoDB Table resource injected by FastAPI dependency.

    Returns:
        A dict containing the latest position item from DynamoDB.

    Raises:
        HTTPException 404: If no position data exists in the table yet.
        HTTPException 503: If the DynamoDB query fails.
    """
    try:
        response = table.query(
            KeyConditionExpression=Key("pk").eq("POSITION"),
            ScanIndexForward=False,
            Limit=1
        )
    except ClientError as e:
        logger.error(f"DynamoDB query failed: {e}")
        raise HTTPException(status_code=503, detail="Database error")
    
    if not response["Items"]:
        raise HTTPException(status_code=404, detail="No position data available.")
    
    return response["Items"][0]


@app.get("/positions")
def read_positions(table=Depends(get_table), limit: int=10):
    """
    Returns a list of recent ISS positions, ordered newest first.
    The limit parameter is capped at 100 to prevent oversized responses.

    Args:
        table: DynamoDB Table resource injected by FastAPI dependency.
        limit: Number of records to return. Defaults to 10, max 100.

    Returns:
        A list of position dicts from DynamoDB.

    Raises:
        HTTPException 503: If the DynamoDB query fails.
    """
    # cap how many records can be queried
    if limit > 100:
        limit = 100

    try:
        response = table.query(
            KeyConditionExpression=Key("pk").eq("POSITION"),
            ScanIndexForward=False,
            Limit=limit
        )
    except ClientError as e:
        logger.error(f"DynamoDB query failed: {e}")
        raise HTTPException(status_code=503, detail="Database error")
    
    return response["Items"]