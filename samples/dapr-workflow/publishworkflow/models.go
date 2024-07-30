// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package publishworkflow

type Sensor struct {
	Name         string  `json:"name"`
	TemperatureF float32 `json:"temperature_f"`
	TemperatureC float32 `json:"temperature_c"`
}
