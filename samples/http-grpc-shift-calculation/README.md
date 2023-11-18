# HTTP/GRPC Shift Calculator

## Usage 

### Server as a Pod

```sh
# From the root of the http-grpc-shift-calculation directory.
docker build ../.. -f Dockerfile -t makocr.azurecr.io/http-grpc-shift-calculation:latest

# Or if running from the root of the explore-iot-operations repository.
# docker build . -f ./samples/http-grpc-shift-calculation/Dockerfile -t makocr.azurecr.io/http-grpc-shift-calculation:latest

# Push or load your newly built image into your cluster, depending on the k8s setup.
# docker push makocr.azurecr.io/http-grpc-shift-calculation:latest # Using AKS + Connected ACR
# minikube load makocr.azurecr.io/http-grpc-shift-calculation:latest # Using minikube
# docker save makocr.azurecr.io/http-grpc-shift-calculation:latest | k3s ctr images import - # Using K3s

kubectl apply -f manifest.yml
```

### Server Configuration

```yaml
logger: # Logger related settings.
  level: 0 # Log level (trace: 0, debug: 1, info: 2, warn: 3, error: 4, critical: 5, fatal: 6, panic: 7)
server: # Server related settings.
  httpPort: 3333 # Port on which to host the HTTP server.
  grpcPort: 4444 # Port on which to host the grpc server.
calculator: # Calculator related settings.
  shifts: 3 # Number of shifts in a 24 hour period.
  initialTime: 2023-11-16T00:00:00-08:00 # The initial time that the first period began (used to adjust start time of shift cycle and configure time zone).
```

## HTTP Specification

__Example Input Message__

```json
// POST "/"
{
    "timestamp": "2023-11-16T8:18:10-08:00"
}
```

__Example Output Message__

```json
// Status 200 OK
{
    "shift": 1,
    "timestamp": "2023-11-16T8:18:10-08:00"
}
```

## GRPC Specification

__Protobuf Definition__

```
syntax = "proto3";

message Message {
    oneof options {
        string string = 1;
        int32 integer = 2;
        double float = 3;
        bool boolean = 4;
    }
    map<string, Message> map = 5;
    repeated Message array = 6;
}

service Sender {
    rpc Send(Message) returns (Message) {}
}
```

__Example Input Message__

```json
// Method Send
{
    "map": {
        "timestamp": {
            "string": "2023-11-16T8:18:10-08:00"
        }
    }
}
```

__Example Output Message__

```json
// Status 0 OK
{
    "map": {
        "timestamp": {
            "string": "2023-11-16T8:18:10-08:00"
        },
        "shift": {
            "integer": 1
        }
    }
}
```