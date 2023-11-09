package formatter

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
		"attempted to create formatter with id %s of non-existent type %s",
		err.identifier,
		err.kind,
	)
}
