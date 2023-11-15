package configuration

type Configuration struct {
	ServerConfiguration    ServerConfiguration
	AlgorithmConfiguration AlgorithmConfiguration
}

type ServerConfiguration struct {
	AnomalyDetectionRoute string
	Port                  int
}

type AlgorithmConfiguration struct {
	PressureSettings    AlgorithmSettings
	TemperatureSettings AlgorithmSettings
	VibrationSettings   AlgorithmSettings
}

type AlgorithmSettings struct {
	EMWALambdaFactor float64
	EMWALFactor      int
	ControlLimitT    float64
	ControlLimitS    float64
}
