// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package edge

import (
	"fmt"

	"github.com/explore-iot-ops/samples/device-simulator/lib/component"
	"github.com/explore-iot-ops/samples/device-simulator/lib/errors"
)

type InvalidPositionError struct {
	errors.BadRequest
	identifier component.ID
}

func (err *InvalidPositionError) Error() string {
	return fmt.Sprintf(
		"could not create the edge with id %q -- for a position type edge, an integer value must be provided",
		err.identifier,
	)
}

type InvalidLabelError struct {
	errors.BadRequest
	identifier component.ID
}

func (err *InvalidLabelError) Error() string {
	return fmt.Sprintf(
		"could not create the edge with id %q -- for a label type edge, a string value must be provided",
		err.identifier,
	)
}

type InvalidTypeError struct {
	errors.BadRequest
	kind       string
	identifier component.ID
}

func (err *InvalidTypeError) Error() string {
	return fmt.Sprintf(
		"attempted to create a edge (identifier %s) with an invalid edge type %s",
		err.identifier,
		err.kind,
	)
}

type InvalidParentNodeTypeError struct {
	errors.BadRequest
	identifier           component.ID
	parentNodeIdentifier component.ID
}

func (err *InvalidParentNodeTypeError) Error() string {
	return fmt.Sprintf(
		"the parent node with id %s of the edge with id %s must be of type collection of array",
		err.parentNodeIdentifier,
		err.identifier,
	)
}

type IdentifierConflictError struct {
	errors.BadRequest
	identifier component.ID
	invalid    component.ID
}

func (err *IdentifierConflictError) Error() string {
	return fmt.Sprintf(
		"edge with id %s cannot have identical child and parent identifiers (id %s)",
		err.identifier,
		err.invalid,
	)
}
