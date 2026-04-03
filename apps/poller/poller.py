# poller.py
#
# This application polls a public api endpoint to fetch position data of the
# International space station. 
import os
import time
import logging
from decimal import Decimal

import boto3
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def init_db(table_name: str, endpoint_url: str | None) -> object:
    """
    Initializes dynamodb connection and returns a table.
    Raises on connection failure or if the table does not exist.
    """
    from botocore.exceptions import EndpointConnectionError, NoRegionError

    try:
        dynamodb = boto3.resource("dynamodb", endpoint_url=endpoint_url)
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

def fetch_iss_data_json(url: str, max_retries: int, 
                        retry_delay_seconds: int,
                        timeout_seconds: int) -> dict:
    """
    fetch iss data from public endpoint. 
    """
    attempt = 0
    while attempt < max_retries:
        logger.info(f"Fetching position data from endpoint {url}")
        attempt += 1
        try:
            r = httpx.get(url, timeout=timeout_seconds)
            return r.json()
        except httpx.ConnectTimeout as e:
            logger.warning(f"Connection timed out on {attempt}/{max_retries} ")
            if attempt < max_retries:
                time.sleep(retry_delay_seconds)
            else:
                logger.error(f"Failed to connect after {max_retries} attempts to {url}")
                raise e
        except httpx.HTTPError as e:
            logger.error(f"HTTP Exception for {e.request.url} - {e}")
            raise e
        except Exception as e:
            logger.error(f"Unexpected error fetching ISS data: {e}")
            raise

def transform_to_db_entry(data: dict) -> dict:
    """
    transform response data into dynamodb-friendly dict
    """
    return {
        "pk": "POSITION",
        "latitude": Decimal(str(data['latitude'])),
        "longitude": Decimal(str(data['longitude'])),
        "altitude": Decimal(str(data['altitude'])),
        "velocity": Decimal(str(data['velocity'])),
        "timestamp": data['timestamp'],
    }

def write_to_db(table: object, data: dict) -> None:
    """
    performs write operation to dynamodb
    """
    logger.info("Writing position entry to db")
    try:
        table.put_item(
            Item=data,
        )
    except Exception as e:
        logger.error(f"Failed to write entry to database table. {e}")
        raise e
    else:
        logger.info("Succecessfully recorded entry in database.")

def push_prometheus_metric() -> None:
    """
    Push last success timestamp to Prometheus Pushgateway.
    Enables alerting when the poller CronJob stops running.
    """
    pushgateway_url = os.environ["PUSHGATEWAY_URL"]
    payload = "# TYPE iss_poller_last_success_timestamp_seconds gauge\niss_poller_last_success_timestamp_seconds {}\n".format(
        int(time.time())
    )
    try:
        r = httpx.post(
            f"{pushgateway_url}/metrics/job/iss_poller",
            content=payload,
            headers={"Content-Type": "text/plain"},
        )
        r.raise_for_status()
        logger.info("Pushed metric to Pushgateway")
    except (httpx.HTTPError, httpx.ConnectTimeout) as e:
        logger.error(f"Failed to push metric to Pushgateway: {e}")

def main():
    """
    primary control logic for poller app
    """
    
    try:
        ## initialize db
        db_table_name = os.environ["DYNAMODB_TABLE"]
        db_endpoint_url = os.getenv("DYNAMODB_ENDPOINT_URL")
        db_table = init_db(db_table_name, db_endpoint_url)
        
        # fetch iss position data
        fetch_url = os.environ["ISS_TRACK_URL"]  
        fetch_max_retries = int(os.getenv("FETCH_MAX_RETRIES", str(5)))
        fetch_retry_delay = int(os.getenv("FETCH_RETRY_DELAY_SECONDS",str(3)))
        fetch_timeout_seconds = int(os.getenv("FETCH_TIMEOUT_SECONDS", str(10)))        
        response_dict = fetch_iss_data_json(fetch_url, fetch_max_retries, 
                                            fetch_retry_delay, fetch_timeout_seconds)
        
        # transform response
        item = transform_to_db_entry(response_dict)   
        
        # write to db
        write_to_db(db_table, item)

        # check if pushgateway is configured (optional dependency)
        # before trying to push prometheus metric
        if os.getenv("PUSHGATEWAY_URL"):
            push_prometheus_metric()
        logger.info("Task completed successfully")
    except Exception as e:
        logger.error(f"Poller failed with unhandled exception: {e}")
        raise
    
if __name__ == '__main__':
    main()