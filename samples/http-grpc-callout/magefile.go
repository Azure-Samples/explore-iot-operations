// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//go:build mage

// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
package main

import (
	//mage:import
	"github.com/explore-iot-ops/lib/mage"
)

func CI() error {
	return mage.CI(
		"github.com/explore-iot-ops/samples/http-grpc-callout/",
		map[string]any{"cmd": nil},
		3000,
		0.00,
		0,
	)
}
