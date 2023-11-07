package outlet

import (
	"errors"
	"testing"

	"github.com/iot-for-all/device-simulation/lib/expression"
	"github.com/iot-for-all/device-simulation/components/formatter"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/stretchr/testify/require"
)

var (
	ErrMock = errors.New("mock error")
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestPrometheusOutlet(t *testing.T) {
	expected := 1.0
	outlet := NewPrometheusOutlet(&expression.MockEvaluator{
		OnEvaluate: func(m map[string]any) (any, error) {
			return expected, nil
		},
	}, &formatter.MockFormatter{
		OnParse: func(b []byte) (any, error) {
			return map[string]any{"": expected}, nil
		},
	}, &registry.MockObservable{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
		},
	})

	err := outlet.Observe(nil)
	require.NoError(t, err)
}

func TestPrometheusOutletIntCast(t *testing.T) {
	expected := 1
	outlet := NewPrometheusOutlet(&expression.MockEvaluator{
		OnEvaluate: func(m map[string]any) (any, error) {
			return expected, nil
		},
	}, &formatter.MockFormatter{
		OnParse: func(b []byte) (any, error) {
			return map[string]any{"": expected}, nil
		},
	}, &registry.MockObservable{
		OnObserve: func(val float64) {
			require.Equal(t, 1.0, val)
		},
	})

	err := outlet.Observe(nil)
	require.NoError(t, err)
}

func TestPrometheusOutletFormatterError(t *testing.T) {
	outlet := NewPrometheusOutlet(&expression.MockEvaluator{}, &formatter.MockFormatter{
		OnParse: func(b []byte) (any, error) {
			return nil, ErrMock
		},
	}, &registry.MockObservable{})

	err := outlet.Observe(nil)
	require.Equal(t, ErrMock, err)
}

func TestPrometheusOutletEvaluatorError(t *testing.T) {
	outlet := NewPrometheusOutlet(&expression.MockEvaluator{
		OnEvaluate: func(m map[string]any) (any, error) {
			return nil, ErrMock
		},
	}, &formatter.MockFormatter{
		OnParse: func(b []byte) (any, error) {
			return map[string]any{"": 0}, nil
		},
	}, &registry.MockObservable{})

	err := outlet.Observe(nil)
	require.Equal(t, ErrMock, err)
}
