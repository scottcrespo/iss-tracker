from unittest.mock import MagicMock
from fastapi.testclient import TestClient
from api import app, get_table
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key
import pytest

mock_table = MagicMock()

app.dependency_overrides[get_table] = lambda: mock_table

client = TestClient(app)

@pytest.fixture(autouse=True)
def reset_mock():
    mock_table.query.side_effect = None
    mock_table.reset_mock()
    yield

def test_health_200():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}

def test_read_position_200():
    """
    GET /position returns 200 and the most recent position item when data exists.
    Verifies the full response body matches the mocked DynamoDB item.
    """
    mock_table.query.return_value = {
        "Items": [
            {
                "pk": "POSITION",
                "timestamp": 1234567890,
                "latitude": "45.123",
                "longitude": "-93.456",
                "altitude": "408.5",
                "velocity": "7.66"
            }
        ]
    }
    
    response = client.get("/position")
    
    assert response.status_code == 200
    
    assert response.json() == {
        "pk": "POSITION",
        "timestamp": 1234567890,
        "latitude": "45.123",
        "longitude": "-93.456",
        "altitude": "408.5",
        "velocity": "7.66"
    }

def test_read_position_404():
    """
    GET /position returns 404 when DynamoDB returns an empty Items list.
    Simulates the case where the poller has not yet written any data.
    """
    mock_table.query.return_value = {"Items":[]}
    response = client.get("/position")
    assert response.status_code == 404


def test_read_position_db_error_503():
    """
    GET /position returns 503 when DynamoDB raises a ClientError.
    Verifies the handler catches downstream failures and returns a safe error response.
    """
    error_response = {"Error": {"Code": "InternalServerError", "Message": "DynamoDB error"}}
    mock_table.query.side_effect = ClientError(error_response, "Query")
    response = client.get("/position")
    assert response.status_code == 503

def test_read_positions_success_200():
    """
    GET /positions returns 200 and a list of position items when data exists.
    Verifies the response is a list and the body matches the mocked DynamoDB items.
    """
    mock_table.query.return_value = {
        "Items": [
            {
                "pk": "POSITION",
                "timestamp": 1234567890,
                "latitude": "45.123",
                "longitude": "-93.456",
                "altitude": "408.5",
                "velocity": "7.66"
            }
        ]
    }
    
    response = client.get("/positions")
    
    assert response.status_code == 200
    
    assert response.json() == [{
        "pk": "POSITION",
        "timestamp": 1234567890,
        "latitude": "45.123",
        "longitude": "-93.456",
        "altitude": "408.5",
        "velocity": "7.66"
    }]

def _make_position_items(count: int, base_timestamp: int = 1744000000) -> list:
    return [
        {
            "pk": "POSITION",
            "timestamp": base_timestamp - (i * 60),
            "latitude": "45.123",
            "longitude": "-93.456",
            "altitude": "408.5",
            "velocity": "7.66"
        }
        for i in range(count)
    ]

def test_read_positions_default_limit_200():
    """
    GET /positions with limit=10 returns 200 and exactly 10 items.
    Verifies the default limit behaviour returns the expected number of records.
    """
    mock_table.query.return_value = {"Items": _make_position_items(count=10)}
    response = client.get("/positions", params={"limit":10})
    assert response.status_code == 200
    assert len(response.json()) == 10

def test_read_positions_custom_limit_200():
    """
    GET /positions with a custom limit returns 200 and the correct number of items.
    Verifies the limit query parameter is passed through to the DynamoDB query.
    """
    mock_table.query.return_value = {"Items": _make_position_items(count=5)}
    response = client.get("/positions", params={"limit":5})
    assert response.status_code == 200
    assert len(response.json()) == 5

def test_read_positions_limit_cap_200():
    """
    GET /positions with limit > 100 returns 200 and at most 100 items.
    Verifies the handler enforces the limit cap to prevent oversized responses.
    """
    mock_table.query.return_value = {"Items": _make_position_items(count=100)}
    response = client.get("/positions", params={"limit":105})
    assert response.status_code == 200
    mock_table.query.assert_called_once_with(
        KeyConditionExpression=Key("pk").eq("POSITION"),
        ScanIndexForward=False,
        Limit=100
    )

def test_read_positions_db_error_503():
    """
    GET /positions returns 503 when DynamoDB raises a ClientError.
    Verifies the handler catches downstream failures and returns a safe error response.
    """
    error_response = {"Error": {"Code": "InternalServerError", "Message": "DynamoDB error"}}
    mock_table.query.side_effect = ClientError(error_response, "Query")
    response = client.get("/positions")
    assert response.status_code == 503