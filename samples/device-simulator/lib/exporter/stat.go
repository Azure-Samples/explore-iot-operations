// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package exporter

import (
	"fmt"
	"os"
)

type InvalidVolumePath struct {
	path string
}

func (err *InvalidVolumePath) Error() string {
	return fmt.Sprintf(
		"no storage directory exists at path %s, please check for misconfigurations",
		err.path,
	)
}

func Stat(path string) error {
	_, err := os.Stat(path)
	if os.IsNotExist(err) {
		return &InvalidVolumePath{
			path: path,
		}
	}
	if err != nil {
		return err
	}

	return nil
}
