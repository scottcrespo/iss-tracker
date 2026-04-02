import os
import time
import logging
from decimal import Decimal

import httpx
from modules.database import table

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def fetch_iss_data_json(url: str) -> dict:
    """
    fetch iss data from public endpoint. 
    """
    logger.info(f"Fetching position data from endpoint {url}")
    try:
        r = httpx.get(url)
    except httpx.HTTPError as e:
        logger.error(f"HTTP Exception for {e.request.url} - {e}")
        raise e
    return r.json()


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


def write_to_db(data: dict) -> None:
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
    except httpx.HTTPError as e:
        logger.error(f"Failed to push metric to Pushgateway: {e}")


def main():
    """
    primary control logic for poller app
    """
    url_env = os.environ["ISS_TRACK_URL"]    
    response_dict = fetch_iss_data_json(url_env)
    item = transform_to_db_entry(response_dict)   
    write_to_db(item)

    # check if pushgateway is configured (optional dependency)
    # before trying to push prometheus metric
    if os.getenv("PUSHGATEWAY_URL"):
        push_prometheus_metric()
    logger.info("Task completed successfully")

if __name__ == '__main__':
    main()