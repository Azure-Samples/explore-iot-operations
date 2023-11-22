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
		"github.com/explore-iot-ops/samples/anomaly-detection/",
		map[string]any{
			"cmd":               nil,
			"lib/configuration": nil,
			"lib/payload":       nil,
		},
		3000,
		0.00,
		0.00,
	)
}
