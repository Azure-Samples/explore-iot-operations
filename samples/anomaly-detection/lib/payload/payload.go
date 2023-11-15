package payload

type InputPayload struct {
	Payload CommonPayload
}

type CommonPayload struct {
	AssetID            string
	AssetName          string
	Humidity           float64
	MachineStatus      int
	MaintainenceStatus string
	Name               string
	OperatingTime      int
	SerialNumber       string
	Site               string
	SourceTimestamp    string
	Temperature        float64
	Vibration          float64
}

type OutputPayload struct {
	Payload OutputInnerPayload
}

type OutputInnerPayload struct {
	CommonPayload
	HumidityAnomalyFactor    float64
	HumidityAnomaly          bool
	TemperatureAnomalyFactor float64
	TemperatureAnomaly       bool
	VibrationAnomalyFactor   float64
	VibrationAnomaly         bool
}
