# callout
This is a HTTP endpoint that can be used to debug or process data in AIO Data Processor using **Call out HTTP**.

## Usage

### Deploy container to Kubernetes cluster

This utility can be deployed as a service in your Kubernetes cluster. You can use the container that is published to ACR(Azure Container Registry) using [setup/service.yaml](setup/service.yaml) . 
```
kubectl apply -f setup/service.yaml
```

### Debugging pipeline
Data Processor has a **Call out HTTP** stage where you can call a HTTP endpoint from with in the pipeline. In that callout stage, you can use the api/echo route to print the contents of the message. Where ever you need to see the message, you can add a callout stage.

|Parameter | Value       | Description  |
|----------|-------------|--------------|
| Method   | GET or POST | any payload sent in the body is printed as pretty JSON |
| URL      | http://callout.default.svc.cluster.local/api/echo/myStage | The URL of the callout endpoint hosted in the cluster. To disambiguate the print outputs, you can use a string like *myStage* or *stage2* etc. |

### Quality factor
You can compute quality factor using a **Call out HTTP** stage hitting this HTTP endpoint. In that callout stage, you can use the api/qfactor route to comput qFactor, Quality and shift.

|Parameter | Value       | Description  |
|----------|-------------|--------------|
| Method   | POST |  |
| URL      | http://callout.default.svc.cluster.local/api/qfactor |  |

#### Input Message ####
```JSON
{
  "Payload": {
    "age": 14,
    "asset_id": "Red_S1",
    "asset_name": "Redmond_Slicer_Redmond_Slicer__asset_0",
    "country": "USA",
    "humidity": 94.49016579867568,
    "id": "Red_S1",
    "machine_status": 0,
    "operating_time": 12527,
    "product": "Takis",
    "site": "Redmond",
    "source_timestamp": "2023-10-18T18:07:45.575Z",
    "temperature": 91.06476575011023,
    "vibration": 45.53238287505511
  },
  "SequenceNumber": 12515,
  "Timestamp": "2023-10-18T11:07:45.566556393-07:00"
}
```
#### Output Message ####
```JSON
{
  "Payload": {
    "age": 14,
    "asset_id": "Red_S1",
    "asset_name": "Redmond_Slicer_Redmond_Slicer__asset_0",
    "country": "USA",
    "humidity": 94.49016579867568,
    "id": "Red_S1",
    "machine_status": 0,
    "operating_time": 12527,
    "pressure": 0,
    "product": "Takis",
    "site": "Redmond",
    "temperature": 91.06476575011023,
    "vibration": 45.53238287505511,
    "q_factor": 0.8,
    "quality": "Good",
    "shift": 3,
    "source_timestamp": "2023-10-18T18:07:45.575Z"
  },
  "SequenceNumber": 12515,
  "Timestamp": "2023-10-18T11:07:45.566556393-07:00"
}
```
