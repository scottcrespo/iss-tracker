from poller import fetch_iss_data_json, transform_to_db_entry
import sys
from unittest.mock import MagicMock, patch
import pytest
import httpx

sys.modules["database"] = MagicMock()

def test_fetch_success():
    """
    Test case verifies response of successful fetch to remote endpoint. 
    poller.httpx.get is patched with MagicMock object.
    """
    mock_response = MagicMock()
    mock_response.json.return_value = {"latitude": 45.0, "longitude": -93.0}

    with patch("poller.httpx.get", return_value=mock_response):
        result = fetch_iss_data_json("http://fake-url",
                                     max_retries=3, retry_delay_seconds=0,
                                     timeout_seconds=3)        
    assert result == {"latitude": 45.0, "longitude": -93.0}

def test_fetch_retries_on_timeout():
    """
    Mock raise httpx.ConnectTimeout and verify function attempted httpx.get() 
    the correct number of retry times rather than exiting early.
    """
    with patch("poller.httpx.get", side_effect=httpx.ConnectTimeout("timed out")) as mock_get:
        with pytest.raises(httpx.ConnectTimeout):
            fetch_iss_data_json("http://fake-url",
                                max_retries=3, retry_delay_seconds=0,
                                timeout_seconds=3)
        assert mock_get.call_count == 3   

def test_fetch_raises_immediately_on_http_error():
    """
    Mock raise httpx.HTTPError and verify function exited immediately
    """
    # instantiate our own HTTPError object with request attribute to satisfy data needs
    # of fetch_iss_data_json
    exc = httpx.HTTPError("http error")
    exc.request = httpx.Request("GET", "http://fake-url")
    with patch("poller.httpx.get", side_effect=exc) as mock_get:
        
        with pytest.raises(httpx.HTTPError):
            fetch_iss_data_json("http://fake-url",
                                max_retries=3, retry_delay_seconds=0,
                                timeout_seconds=3)
        assert mock_get.call_count == 1