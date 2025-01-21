# Authentication Server Debugging in K8s

Once the service is running in the cluster, use the following steps to test it manually.

## Sending Http Request

Follow [this article](https://learn.microsoft.com/en-us/azure/iot-operations/manage-mqtt-broker/howto-test-connection?tabs=portal#connect-to-the-default-listener-inside-the-cluster) to create the MQTT testing pod and connect to it.

Once connected, follow these steps:

1. Create Http Request

    ``` bash
    cat <<EOF > authrequest.txt
    {
    "type": "connect",
    "username": "username1",
    "password": "password1"
    }
    EOF
    ```

2. Install Curl

    ``` bash
    apk update && apk add curl
    ```

3. Send Http Request

    ``` bash
   curl -v --cacert /var/run/certs/ca.crt -X POST -H "Content-Type: application/json" -d @authrequest.txt  https://auth-server-user-pass-mqtt/?api-version=0.5.0
    ```
