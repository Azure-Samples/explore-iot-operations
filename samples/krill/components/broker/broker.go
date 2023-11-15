// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package broker provides the implementation of the broker component of the simulation framework.
package broker

import (
	"fmt"

	"github.com/explore-iot-ops/samples/krill/components/registry"
)

type Source interface {
	Target
	registry.Observable
}

type Target interface {
	Endpoint() string
}

// Broker is a representation of an MQTT broker, containing that broker's endpoint and port.
// It also implements the Observable interface, allowing for monitoring based on other
// components which use this broker.
type Broker struct {
	Broker   string
	Port     int
	endpoint string
	registry.Observable
}

// New creates a new broker, given an observable monitor.
// Optional parameters can be set through the options function.
func New(mon registry.Observable, options ...func(*Broker)) *Broker {
	broker := &Broker{
		Observable: mon,
		Broker:     "",
		Port:       0,
		endpoint:   "",
	}

	for _, option := range options {
		option(broker)
	}

	broker.endpoint = fmt.Sprintf("%s:%d", broker.Broker, broker.Port)

	return broker
}

func (broker *Broker) Endpoint() string {
	return broker.endpoint
}

type MockBroker struct {
	registry.Observable
	OnEndpoint func() string
}

func (broker *MockBroker) Endpoint() string {
	return broker.OnEndpoint()
}
