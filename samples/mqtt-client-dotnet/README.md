# .NET sample application for E4k

This is a .NET sample used to demonstrate how to connect an in-cluster Pod using MQTTnet to IoT MQ, using a Kubernetes service account token (SAT).

You can build the image yourself, or simply jump to [Run the container](#run-the-container) to use a pre-built image.

## Create a service account for client

To create SATs, first create a Service Account. The command below creates a Service Account called `mqtt-client`.

```bash
kubectl create serviceaccount mqtt-client
```

## Build the Docker image

To build the docker image, execute the following command:

```bash
docker build . -t mqtt-client-dotnet
```

## Push the Docker image to a Container Registry

Tag and push the container to your container registry:

1. Tag the image using the `docker tag` command: 

    ```bash
    docker tag mqtt-client-dotnet $CONTAINER_REGISTRY/mqtt-client-dotnet
    ```

1. Use `docker push` to push the image to the registry instance:

    ```bash
    docker push $CONTAINER_REGISTRY/mqtt-client-dotnet
    ```

## Run the container

[!TIP] The Pod definition below uses a pre-built image. Substitute with the image from your own Container registry if desired.

Create a file named `pod.yaml` with the following contents:

1. Update the supplied [./deploy/pod.yaml](./deploy/pod.yaml) file to use the Azure Container Registry image for the `spec.containers.image` value, and to include the image pull secret in an `spec.imagePullSecrets` section. For example:

    ```yaml
    apiVersion: v1
    kind: Pod
    metadata:
      name: mqtt-client-dotnet
      labels:
        app: publisher
    spec:
      serviceAccountName: mqtt-client
      volumes: 
        - name: mqtt-client-token
          projected:
            sources:
            - serviceAccountToken:
                path: mqtt-client-token
                audience: aio-mq-dmqtt
                expirationSeconds: 86400
      containers:
        - name: mqtt-client-dotnet
          image: ghcr.io/azure-samples/explore-iot-operations/mqtt-client-dotnet:latest
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: mqtt-client-token
              mountPath: /var/run/secrets/tokens
    ```

1. Deploy the pod:

    ```bash
    kubectl apply -f pod.yaml
    ```

1. View the logs of the pod publishing messages using:

    ```bash
    kubectl logs mqtt-client-dotnet
    ```
