import pytest
from unittest.mock import MagicMock


@pytest.fixture
def mock_client():
    client = MagicMock()
    client.get_monitors.return_value = []
    return client
