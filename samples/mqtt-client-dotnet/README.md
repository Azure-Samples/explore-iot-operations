# .NET sample application for E4k

This is a .NET sample used to demonstrate how to connect an in-cluster application using MQTTnet to the IoT Operations MQTT Brokerm using a Kubernetes service account token (SAT) for authentication.

## Create the image

> [!TIP] 
> You can build the image yourself as outlined in this section, or jump to [Run the application](#run-the-application) to use a pre-built image.

1. Build the container:

    ```bash
    dotnet publish --os linux --arch x64 /t:PublishContainer    
    ```

1. Tag and push the container to your container registry:

    ```bash
    docker tag mqtt-client-dotnet $CONTAINER_REGISTRY/mqtt-client-dotnet
    docker push $CONTAINER_REGISTRY/mqtt-client-dotnet
    ```

    **or** push to your k3d cluster:

    ```bash
    k3d image import mqtt-client-dotnet
    ```

## Run the application

> [!TIP] 
> The Pod definition below uses a pre-built image. Substitute with the image from your own container registry if desired.

1. Create a file named `app.yaml` with the following:

    ```yaml
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: mqtt-client
      namespace: azure-iot-operations
    ---
    apiVersion: v1
    kind: Pod
    metadata:
      name: mqtt-client-dotnet
      namespace: azure-iot-operations
    spec:
      serviceAccountName: mqtt-client
      volumes: 
      - name: mqtt-client-token
        projected:
          sources:
          - serviceAccountToken:
              path: mqtt-client-token
              audience: aio-mq
              expirationSeconds: 86400
      - name: aio-ca-trust-bundle
        configMap:
          name: aio-ca-trust-bundle-test-only
      containers:
      - name: mqtt-client-dotnet
        image: ghcr.io/azure-samples/explore-iot-operations/mqtt-client-dotnet:latest
        volumeMounts:
        - name: mqtt-client-token
          mountPath: /var/run/secrets/tokens/
        - name: aio-ca-trust-bundle
          mountPath: /var/run/certs/aio-mq-ca-cert/
        env:
        - name: hostname
          value: "aio-mq-dmqtt-frontend"
        - name: tcpPort
          value: "8883"
        - name: useTls
          value: "true"
        - name: caFile
          value: "/var/run/certs/aio-mq-ca-cert/ca.crt"
        - name: satAuthFile
          value: "/var/run/secrets/tokens/mqtt-client-token"
    ```

2. Deploy the pod to your cluster:

    ```bash
    kubectl apply -f app.yaml
    ```

3. View the logs:

    ```bash
    kubectl logs mqtt-client-dotnet
    ```
