package node

import (
	"fmt"

	"github.com/iot-for-all/device-simulation/lib/errors"
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