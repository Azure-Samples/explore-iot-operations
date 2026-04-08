Here’s the full specification regenerated in clean Markdown format. You can copy and paste this into a `.md` file (e.g., `spaceship_factory_spec.md`) for use in your simulator project.

***

# 🚀 Spaceship Factory IoT Simulation Data Specification

This document defines the MQTT JSON message payloads for a simulated factory that manufactures and assembles spaceship parts and full spaceships. The messages are designed to support real-time telemetry and enable calculation of Overall Equipment Effectiveness (OEE), including its three components: **Availability**, **Performance**, and **Quality**.

## Overview

### Factory Components

*   CNC Machines
*   3D Printers
*   Welding Stations
*   Painting Booths
*   Testing Rigs
*   Customer Order System
*   Dispatch & Fulfillment System

### Message Characteristics

*   **Format**: JSON
*   **Transport**: MQTT
*   **Frequency**: \~1 message/second aggregate across all machines
*   **Scope**: Live telemetry only (no batch or shift summaries)
*   **Purpose**: Enable OEE calculation and support data exploration

***

## 📡 Message Types and Payloads

### 1. CNC Machine Telemetry

```json
{
  "timestamp": "2025-10-29T14:22:00Z",
  "machine_id": "CNC-01",
  "station_id": "LINE-1-STATION-A",
  "status": "running",
  "part_type": "HullPanel",
  "part_id": "HP-1001",
  "cycle_time": 12.5,
  "quality": "good"
}
```

| Field        | Type   | Description                              |
| ------------ | ------ | ---------------------------------------- |
| `timestamp`  | string | ISO 8601 UTC timestamp                   |
| `machine_id` | string | Unique CNC machine ID                    |
| `station_id` | string | Production line/station ID               |
| `status`     | string | Machine status (`running`, `idle`, etc.) |
| `part_type`  | string | Type of part produced                    |
| `part_id`    | string | Unique part identifier                   |
| `cycle_time` | number | Time in seconds for last cycle           |
| `quality`    | string | Quality result (`good`, `scrap`)         |

***

### 2. 3D Printer Telemetry

```json
{
  "timestamp": "2025-10-29T14:22:05Z",
  "machine_id": "3DP-07",
  "station_id": "LINE-1-STATION-B",
  "status": "running",
  "part_type": "GearboxCasing",
  "part_id": "GC-483",
  "progress": 0.5,
  "quality": null
}
```

| Field        | Type        | Description                                                |
| ------------ | ----------- | ---------------------------------------------------------- |
| `timestamp`  | string      | ISO 8601 UTC timestamp                                     |
| `machine_id` | string      | 3D printer ID                                              |
| `station_id` | string      | Station ID                                                 |
| `status`     | string      | Printer status                                             |
| `part_type`  | string      | Type of part being printed                                 |
| `part_id`    | string      | Unique part ID                                             |
| `progress`   | number      | Progress (0.0 to 1.0)                                      |
| `quality`    | string/null | Quality result (`good`, `scrap`, or `null` if in progress) |

***

### 3. Welding Station Telemetry

```json
{
  "timestamp": "2025-10-29T14:22:10Z",
  "machine_id": "WELD-02",
  "station_id": "LINE-2-STATION-C",
  "status": "idle",
  "assembly_id": "A-210",
  "assembly_type": "FrameAssembly",
  "last_cycle_time": 8.0,
  "quality": "good"
}
```

| Field             | Type   | Description                   |
| ----------------- | ------ | ----------------------------- |
| `timestamp`       | string | Event timestamp               |
| `machine_id`      | string | Welding machine ID            |
| `station_id`      | string | Station ID                    |
| `status`          | string | Machine status                |
| `assembly_id`     | string | Assembly identifier           |
| `assembly_type`   | string | Type of assembly              |
| `last_cycle_time` | number | Time in seconds for last weld |
| `quality`         | string | Quality result                |

***

### 4. Painting Booth Telemetry

```json
{
  "timestamp": "2025-10-29T14:22:10Z",
  "machine_id": "PAINT-05",
  "station_id": "LINE-2-STATION-D",
  "status": "running",
  "part_id": "Frame-210",
  "color": "#FFD700",
  "cycle_time": 5.0,
  "quality": "good"
}
```

| Field        | Type   | Description            |
| ------------ | ------ | ---------------------- |
| `timestamp`  | string | Event timestamp        |
| `machine_id` | string | Paint booth ID         |
| `station_id` | string | Station ID             |
| `status`     | string | Booth status           |
| `part_id`    | string | Part ID                |
| `color`      | string | Paint color (hex code) |
| `cycle_time` | number | Time in seconds        |
| `quality`    | string | Paint job quality      |

***

### 5. Testing Rig Telemetry

```json
{
  "timestamp": "2025-10-29T14:22:15Z",
  "machine_id": "TEST-01",
  "station_id": "QA-STATION-1",
  "status": "testing",
  "target_id": "Spaceship-42",
  "target_type": "FullSpaceship",
  "test_result": "pass",
  "issues_found": 0
}
```

| Field          | Type   | Description             |
| -------------- | ------ | ----------------------- |
| `timestamp`    | string | Time of test            |
| `machine_id`   | string | Testing rig ID          |
| `station_id`   | string | QA station ID           |
| `status`       | string | Rig status              |
| `target_id`    | string | ID of item tested       |
| `target_type`  | string | Type of item            |
| `test_result`  | string | Result (`pass`, `fail`) |
| `issues_found` | number | Number of issues found  |

***

### 6. Customer Order Event

```json
{
  "timestamp": "2025-10-29T14:22:20Z",
  "event_type": "order_placed",
  "order_id": "ORD-1001",
  "items": [
    { "product_type": "FullSpaceship", "quantity": 1 },
    { "product_type": "SparePartKit",  "quantity": 2 }
  ]
}
```

| Field        | Type   | Description           |
| ------------ | ------ | --------------------- |
| `timestamp`  | string | Time of order         |
| `event_type` | string | `"order_placed"`      |
| `order_id`   | string | Unique order ID       |
| `items`      | array  | List of ordered items |

***

### 7. Dispatch Event

```json
{
  "timestamp": "2025-10-29T14:22:30Z",
  "event_type": "order_dispatched",
  "order_id": "ORD-1001",
  "destination": "Moon Base Alpha",
  "carrier": "SpaceX Starship"
}
```

| Field         | Type   | Description          |
| ------------- | ------ | -------------------- |
| `timestamp`   | string | Dispatch time        |
| `event_type`  | string | `"order_dispatched"` |
| `order_id`    | string | Order ID             |
| `destination` | string | Delivery location    |
| `carrier`     | string | Shipping method      |

***

## 🧮 OEE Metrics Support

Each message contributes to OEE calculation:

*   **Availability**: Derived from `status` fields and timestamps (uptime vs downtime).
*   **Performance**: Based on `cycle_time` vs ideal cycle time.
*   **Quality**: Based on `quality` fields (`good` vs `scrap` or `fail`).


### 🟢 Availability

Measured as the percentage of scheduled time that the machine is actually operating.

**Supported by:**

*   `status` field in all machine payloads (e.g., `"running"`, `"idle"`, `"faulted"`)
*   `timestamp` to track uptime/downtime intervals
*   Machines: CNC, 3D Printer, Welding, Painting, Testing

***

### 🟡 Performance

Measured as the speed at which the machine operates compared to its ideal cycle time.

**Supported by:**

*   `cycle_time` or `last_cycle_time` fields in CNC, Welding, Painting payloads
*   `progress` field in 3D Printer payloads (to monitor pacing)
*   `timestamp` to calculate throughput over time

***

### 🔴 Quality

Measured as the proportion of good parts produced versus total parts.

**Supported by:**

*   `quality` field in CNC, 3D Printer, Welding, Painting payloads (`"good"`, `"scrap"`, `"rework"`)
*   `test_result` and `issues_found` in Testing Rig payloads
*   `part_id`, `assembly_id`, `target_id` to track individual units

***
