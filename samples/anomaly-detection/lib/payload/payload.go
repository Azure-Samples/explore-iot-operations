// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package payload

type InputPayload struct {
	Payload CommonPayload `json:"payload"`
}

type Payload[T any] struct {
	Payload T `json:"payload"`
}

type CommonPayload struct {
	AssetID            string  `json:"asset_id"`
	AssetName          string  `json:"asset_name"`
	MaintainenceStatus string  `json:"maintainence_status"`
	Name               string  `json:"name"`
	SerialNumber       string  `json:"serialNumber"`
	Site               string  `json:"site"`
	SourceTimestamp    string  `json:"source_timestamp"`
	OperatingTime      int     `json:"operating_time"`
	MachineStatus      int     `json:"machineStatus"`
	Humidity           float64 `json:"humidity"`
	Temperature        float64 `json:"temperature"`
	Vibration          float64 `json:"vibration"`
}

type OutputPayload struct {
	Payload OutputInnerPayload `json:"payload"`
}

type OutputInnerPayload struct {
	CommonPayload
	HumidityAnomalyFactor    float64 `json:"humidityAnomalyFactor"`
	HumidityAnomaly          bool    `json:"humidityAnomaly"`
	TemperatureAnomalyFactor float64 `json:"temperatureAnomalyFactor"`
	TemperatureAnomaly       bool    `json:"temperatureAnomaly"`
	VibrationAnomalyFactor   float64 `json:"vibrationAnomalyFactor"`
	VibrationAnomaly         bool    `json:"vibrationAnomaly"`
}
