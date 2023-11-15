// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package limiter

import (
	"context"
	"testing"
	"time"

	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID            = "MockID"
	MockLimit         = 1
	MockPeriodSeconds = 2
	MockInvalid       = 0
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Limiter[struct{}], component.ID])
	require.True(t, ok)
}

func TestLimiterService(t *testing.T) {

	expectedDuration := time.Duration(MockPeriodSeconds) * time.Second

	service := NewService(
		context.Background(),
		&component.MockStore[Limiter[struct{}], component.ID]{
			OnCreate: func(entity Limiter[struct{}], identifier component.ID) error {
				res, ok := entity.(*TimedLimiter[struct{}])
				require.True(t, ok)
				require.Equal(t, MockLimit, res.Limit)
				require.Equal(t, expectedDuration, res.Period)
				return nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		PeriodSeconds: MockPeriodSeconds,
		Limit:         MockLimit,
	})
	require.NoError(t, err)
}

func TestLimiterServiceLimitError(t *testing.T) {
	service := NewService(context.Background(), nil)

	err := service.Create(MockID, &Component{
		Limit: MockInvalid,
	})
	require.Equal(t, &InvalidLimitError{
		value: MockInvalid,
	}, err)
}

func TestLimiterServicePeriodSecondsError(t *testing.T) {
	service := NewService(context.Background(), nil)

	err := service.Create(MockID, &Component{
		Limit:         MockLimit,
		PeriodSeconds: MockInvalid,
	})
	require.Equal(t, &InvalidPeriodSecondsError{
		value: MockInvalid,
	}, err)
}
