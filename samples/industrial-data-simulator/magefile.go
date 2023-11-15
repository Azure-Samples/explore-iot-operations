// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//go:build mage

package main

import (
	//mage:import
	"github.com/explore-iot-ops/lib/mage"
)

func CI() error {
	return mage.CI(
		"github.com/explore-iot-ops/samples/industrial-data-simulator/",
		map[string]any{"cmd": nil},
		3000,
		0.00,
		82.50,
	)
}
