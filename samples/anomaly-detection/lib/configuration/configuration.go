package configuration

type Configuration struct {
	ServerConfiguration    ServerConfiguration    `json:"server" yaml:"server"`
	LoggerConfiguration    LoggerConfiguration    `json:"logger" yaml:"logger"`
	AlgorithmConfiguration AlgorithmConfiguration `json:"algorithm" yaml:"algorithm"`
}

type LoggerConfiguration struct {
	Level int `json:"level" yaml:"level"`
}

type ServerConfiguration struct {
	AnomalyDetectionRoute string `json:"route" yaml:"route"`
	Port                  int    `json:"port" yaml:"port"`
}

type AlgorithmConfiguration struct {
	HumiditySettings    AlgorithmSettings `json:"humidity" yaml:"humidity"`
	TemperatureSettings AlgorithmSettings `json:"temperature" yaml:"temperature"`
	VibrationSettings   AlgorithmSettings `json:"vibration" yaml:"vibration"`
}

type AlgorithmSettings struct {
	EWMALambdaFactor float64 `json:"lambda" yaml:"lambda"`
	EWMALFactor      int     `json:"lFactor" yaml:"lFactor"`
	Type             string  `json:"type" yaml:"type"`
	ControlLimitT    float64 `json:"controlT" yaml:"controlT"`
	ControlLimitS    float64 `json:"controlS" yaml:"controlS"`
	ControlLimitN    float64 `json:"controlN" yaml:"controlN"`
}
