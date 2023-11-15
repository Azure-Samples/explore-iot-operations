// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package client

import (
	"fmt"

	"github.com/explore-iot-ops/samples/device-simulator/lib/errors"
)

type BrokerConnectionError struct {
	errors.BadRequest
	id       string
	endpoint string
	err      error
}

func (err *BrokerConnectionError) Error() string {
	return fmt.Sprintf(
		"mqtt client with id=%s could not connect to MQTT broker at endpoint %s: %q",
		err.id,
		err.endpoint,
		err.err.Error(),
	)
}

type UnknownClientTypeError struct {
	errors.BadRequest
	name string
}

func (err *UnknownClientTypeError) Error() string {
	return fmt.Sprintf("no such %s type for mqtt client component", err.name)
}
