import os
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

def main():
    """
    primary control logic for app function
    """
    url_env = os.environ["ISS_TRACK_URL"]
    response_dict = fetch_iss_data_json(url_env)
    item = transform_to_db_entry(response_dict)
    write_to_db(item)

if __name__ == '__main__':
    main()    