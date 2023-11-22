// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package shift

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestShiftCalculator(t *testing.T) {
	initialTime := time.Date(2000, time.August, 19, 0, 0, 0, 0, time.UTC)
	calculator := &ShiftCalculator{
		Shifts:        3,
		CycleDuration: time.Hour * 24,
		InitialTime:   initialTime,
	}

	next := initialTime.Add(time.Hour)
	cycles, shift := calculator.Calculate(next)
	require.Equal(t, 0, shift)
	require.Equal(t, 0, cycles)

	next = next.Add(time.Hour * 8)
	cycles, shift = calculator.Calculate(next)
	require.Equal(t, 1, shift)
	require.Equal(t, 0, cycles)

	next = next.Add(time.Hour * 8)
	cycles, shift = calculator.Calculate(next)
	require.Equal(t, 2, shift)
	require.Equal(t, 0, cycles)

	next = next.Add(time.Hour * 8)
	cycles, shift = calculator.Calculate(next)
	require.Equal(t, 0, shift)
	require.Equal(t, 1, cycles)
}
