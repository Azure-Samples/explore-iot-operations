// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package formatter

import (
	"fmt"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/errors"
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
