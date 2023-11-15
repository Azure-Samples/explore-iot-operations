// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

type Configuration struct {
	LoggerConfiguration `json:"logger" yaml:"logger"`
	ServerConfiguration `json:"servers" yaml:"servers"`
	Outputs             []Output `json:"outputs" yaml:"outputs"`
}

type LoggerConfiguration struct {
	Level int `json:"level" yaml:"level"`
}

type ServerConfiguration struct {
	HTTPServer `json:"http" yaml:"http"`
	GRPCServer `json:"grpc" yaml:"grpc"`
}

type HTTPServer struct {
	Resources []Resource `json:"resources" yaml:"resources"`
	Port      int        `json:"port" yaml:"port"`
}

type GRPCServer struct {
	Outputs []string `json:"outputs" yaml:"outputs"`
	Port    int      `json:"port" yaml:"port"`
}

type Resource struct {
	Path     string   `json:"path" yaml:"path"`
	Method   string   `json:"method" yaml:"method"`
	Status   int      `json:"status" yaml:"status"`
	Response string   `json:"response" yaml:"response"`
	Outputs  []string `json:"outputs" yaml:"outputs"`
}

type Output struct {
	Name     string `json:"name" yaml:"name"`
	Path     string `json:"path" yaml:"path"`
	Type     string `json:"type" yaml:"type"`
	QoS      int    `json:"qos" yaml:"qos"`
	Endpoint string `json:"endpoint" yaml:"endpoint"`
}
