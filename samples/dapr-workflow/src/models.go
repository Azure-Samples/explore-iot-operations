package main

type SensorPayload struct {
	Name         string  `json:"name"`
	TemperatureF float32 `json:"temperature_f"`
	TemperatureC float32 `json:"temperature_c"`
}
