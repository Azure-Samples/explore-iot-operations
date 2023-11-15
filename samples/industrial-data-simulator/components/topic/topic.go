// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package topic provides the implementation for the topic component of the simulation framework.
package topic

import (
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
)

// Renderer is an interface whose implementation should be able to render a topic name when called and should also implement the registry observable interface.
type Renderer interface {
	Render() string
	registry.Observable
}

// Topic is an implementation of the Renderer interface which has the ability to render a predefined topic name when its Render function is called.
type Topic struct {
	Topic string
	registry.Observable
}

// New creates a topic given an observable.
// Optional parameters can be provided using the options function.
func New(mon registry.Observable, options ...func(*Topic)) *Topic {
	topic := &Topic{
		Topic:      "/",
		Observable: mon,
	}

	for _, option := range options {
		option(topic)
	}

	return topic
}

// Render returns the predefined topic name.
func (topic *Topic) Render() string {
	return topic.Topic
}
