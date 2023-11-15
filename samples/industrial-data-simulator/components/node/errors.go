// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package node

import (
	"fmt"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/errors"
)

type InvalidConfigurationError struct {
	errors.BadRequest
	identifier string
}

func (err *InvalidConfigurationError) Error() string {
	return fmt.Sprintf(
		"attempted to created an expression node with identifier %s with a non-string configuration",
		err.identifier,
	)
}

type InvalidTypeError struct {
	errors.BadRequest
	kind       string
	identifier string
}

func (err *InvalidTypeError) Error() string {
	return fmt.Sprintf(
		"attempted to create a node (identifier %s) with an invalid node type %s",
		err.identifier,
		err.kind,
	)
}
