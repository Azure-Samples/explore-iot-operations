# GRPC/HTTP Callout Server

GRPC/HTTP Callout Server is a server for testing the http and grpc callout capabilities of the Azure IoT Operations data processor.

## Usage

### Server as a Pod

```sh
# From the root of the http-grpc-callout directory.
docker build ../.. -f Dockerfile -t makocr.azurecr.io/http-grpc-callout:latest

# Or if running from the root of the explore-iot-operations repository.
# docker build . -f ./samples/http-grpc-callout/Dockerfile -t makocr.azurecr.io/http-grpc-callout:latest

# Push or load your newly built image into your cluster, depending on the k8s setup.
# docker push makocr.azurecr.io/http-grpc-callout:latest # Using AKS + Connected ACR
# minikube load makocr.azurecr.io/http-grpc-callout:latest # Using minikube
# docker save makocr.azurecr.io/http-grpc-callout:latest | k3s ctr images import - # Using K3s

kubectl apply -f manifest.yml
```

### Configuration

```yaml
logger: # Log level (trace: 0, debug: 1, info: 2, warn: 3, error: 4, critical: 5, fatal: 6, panic: 7)
  level: 0
servers:
  http: 
    port: 3333 # Port on which to host the HTTP server.
    resources: # List of resources to host for the HTTP server.
      - path: /example # Route of the resource.
        method: GET # Method from which to obtain the resource.
        status: 200 # Status to be returned when this resource is requested.
        outputs: ["output1", "output2"] # Output destinations to send the HTTP request body, if such a request body is present (see output setup below).
        response: | # Response to be returned when this resource is requested.
          {
            "hello": "world"
          }
      - path: /example
        method: POST
        status: 200
        outputs: ["output3", "output4"]
        response: |
          {
            "hello": "world1"
          }
  grpc:
    port: 3334 # Port to host the grpc server.
    outputs: ['output1', 'output4'] # Outputs of the GRPC server.
outputs: # Outputs are places which HTTP and GRPC request bodies can be forwarded, such that they can be observed.
  - name: output1 # Name of the output, which is used to cross reference the outputs listed in the HTTP server and GRPC server definitions.
    type: stdout # Type of the output (either stdout or mqtt).
  - name: output2
    type: mqtt
    qos: 1 # For MQTT type outputs, qos determines the qos level of the message being sent.
    path: default/output1 # Path at which to send the mqtt output message.
    endpoint: localhost:1883 # Endpoint of the mqtt broker.
  - name: output3
    type: mqtt
    qos: 1
    path: default/output2
    endpoint: localhost:1883
  - name: output4
    type: mqtt
    qos: 1
    path: grpc/example
    endpoint: localhost:1883
```