# auth-server-template

This is a sample server for Azure IoT MQ broker custom authentication.

The custom authentication feature of the IoT MQ broker provides an extension point that allows customers to plug in an authentication server to authenticate clients that connect to the MQTT broker. The server here is intended as a sample for how such a custom authentication can be implemented.

## Deploying the template

A private preview image of the template is available with the tag `ghcr.io/azure-samples/explore-iot-operations/auth-server-template:0.5.0`. You only need to deploy the template yourself once you make modifications.

The template server needs to be built and deployed as a Kubernetes service. You will need to provide the repository for hosting its container image.

To deploy, run the [build_image.sh](deploy/build_image.sh) script and pass the image tag to use. This script builds and pushes the template image.

```sh
IMAGE_TAG=example.example.io/auth-server-template:latest ./deploy/build_image.sh
```

## Running the template

1. If you are using your own container register, edit [auth-server-template.yaml](deploy/auth-server-template.yaml#L10) and set the image that you created in the previous section.

2. Deploy the pod and service for the template. This template uses both server and client certificates issued by Cert-Manager, and Azure IoT Operations’ trust bundle.
   
    ```sh
      kubectl apply -f ./deploy/auth-server-template.yaml
    ```

3. When finished, run this command to delete resources.
   
    ```sh
     kubectl delete -f ./deploy/auth-server-template.yaml
    ```

## Using the template

Add an MQ BrokerAuthentication with custom authentication. An example BrokerAuthentication is below:

```yaml
apiVersion: mq.iotoperations.azure.com/v1beta1
kind: BrokerAuthentication
metadata:
  name: custom-authn
spec:
  authenticationMethods:
    - method: Custom
      customSettings:
        # Endpoint for custom authentication requests. Required.
        endpoint: https://auth-server-template
        # Optional CA certificate for validating the custom authentication server's certificate.
        caCertConfigMap: custom-auth-ca
        # Authentication between MQTT broker with the custom authentication server.
        # The broker may present X.509 credentials or no credentials to the server.
        auth:
          x509:
            secretRef: custom-auth-client-cert
            namespace: azure-iot-operations
        # Optional additional HTTP headers that the broker will send to the
        # custom authentication server.
        headers:
          header_key: header_value
```

The auth server template will approve authentication requests from all clients, except clients providing usernames that start with `deny`. It will set a credential expiration of 10 seconds for any clients providing usernames that start with `expire`.
