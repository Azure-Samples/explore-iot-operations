# .NET sample application

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

    **or** push to your k3d cluster directly:

    ```bash
    k3d image import mqtt-client-dotnet
    ```

## Run the application

> [!TIP] 
> The Pod definition for this sample uses a pre-built image. Substitute with the image from your own container registry if desired.
> If using a image imported into k3d, set the `imagePullPolicy` to `Never`.

2. Deploy the pod to your cluster:

    ```bash
    kubectl apply -f app.yaml
    ```

3. View the logs to verify the application is publishing successfully:

    ```bash
    kubectl logs mqtt-client-dotnet
    ```

    expected output:
    ```output
    Started MQTT client.
    Reading environment variables.
    CA cert read.
    SAT token read.
    The MQTT client is connected.
    The MQTT client published the message: samplepayload1
    The MQTT client published the message: samplepayload2
    The MQTT client published the message: samplepayload3
    The MQTT client published the message: samplepayload4
    The MQTT client published the message: samplepayload5
    ...
    ```
