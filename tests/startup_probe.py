"""Run the service startup path up to the SDK boundary without networking."""

import ReceiveMessages as service


class OfflineClient:
    @classmethod
    def create_from_connection_string(cls, connection):
        assert connection == service.IOT_CONNECTION_STRING
        print("STARTED", flush=True)
        raise SystemExit(0)


service.check_internet_connection = lambda: True
service.wait_for_clock_sync = lambda: 0
service.IoTHubDeviceClient = OfflineClient
service.main()
