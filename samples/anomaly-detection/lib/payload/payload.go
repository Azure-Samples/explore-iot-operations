// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package payload

type InputPayload struct {
	Payload InputInnerPayload `json:"payload"`
}

type InputInnerPayload struct {
	CommonPayload
	OperatingTime int `json:"operating_time"`
	MachineStatus int `json:"machine_status"`
}

type Payload[T any] struct {
	Payload T `json:"payload"`
}

type CommonPayload struct {
	AssetID           string  `json:"assetId"`
	AssetName         string  `json:"assetName"`
	MaintenanceStatus string  `json:"maintenanceStatus"`
	Name              string  `json:"name"`
	SerialNumber      string  `json:"serialNumber"`
	Site              string  `json:"site"`
	SourceTimestamp   string  `json:"sourceTimestamp"`
	Humidity          float64 `json:"humidity"`
	Temperature       float64 `json:"temperature"`
	Vibration         float64 `json:"vibration"`
}

type OutputPayload struct {
	Payload OutputInnerPayload `json:"payload"`
}

type OutputInnerPayload struct {
	CommonPayload
	OperatingTime            int     `json:"operatingTime"`
	MachineStatus            int     `json:"machineStatus"`
	HumidityAnomalyFactor    float64 `json:"humidityAnomalyFactor"`
	HumidityAnomaly          bool    `json:"humidityAnomaly"`
	TemperatureAnomalyFactor float64 `json:"temperatureAnomalyFactor"`
	TemperatureAnomaly       bool    `json:"temperatureAnomaly"`
	VibrationAnomalyFactor   float64 `json:"vibrationAnomalyFactor"`
	VibrationAnomaly         bool    `json:"vibrationAnomaly"`
}
