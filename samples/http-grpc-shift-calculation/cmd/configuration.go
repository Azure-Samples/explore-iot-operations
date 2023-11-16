package main

type Configuration struct {
	LoggerConfiguration     LoggerConfiguration     `json:"logger" yaml:"logger"`
	ServerConfiguration     ServerConfiguration     `json:"server" yaml:"server"`
	CalculatorConfiguration CalculatorConfiguration `json:"calculator" yaml:"calculator"`
}

type LoggerConfiguration struct {
	Level int `json:"level" yaml:"level"`
}

type ServerConfiguration struct {
	GRPCPort int `json:"grpcPort" yaml:"grpcPort"`
	HTTPPort int `json:"httpPort" yaml:"httpPort"`
}

type CalculatorConfiguration struct {
	Shifts int `json:"shifts" yaml:"shifts"`
}