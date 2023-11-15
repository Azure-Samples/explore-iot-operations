// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package component

type NotFoundError struct{}

func (err *NotFoundError) Error() string {
	return "not found"
}
