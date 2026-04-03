from unittest.mock import MagicMock
from fastapi.testclient import TestClient
from api import app, get_table

mock_table = MagicMock()

app.dependency_overrides[get_table] = lambda: mock_table

client = TestClient(app)

def test_position_200():
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
