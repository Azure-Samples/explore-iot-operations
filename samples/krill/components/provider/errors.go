package provider

import (
	"fmt"

	"github.com/iot-for-all/device-simulation/lib/errors"
)

type InvalidTypeError struct {
	errors.BadRequest
	identifier string
	kind       string
}

func (err *InvalidTypeError) Error() string {
	return fmt.Sprintf(
		"could not create the provider component with id %s because an invalid provider type of %s was given",
		err.identifier,
		err.kind,
	)
}