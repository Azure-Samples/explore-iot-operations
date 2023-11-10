//go:build mage

package main

import (
	//mage:import
	"github.com/explore-iot-ops/lib/mage"
)

func CI() error {
	return mage.CI(
		"github.com/explore-iot-ops/samples/krill/",
		map[string]any{"cmd/krill": nil},
		3000,
		0.00,
		82.50,
	)
}
