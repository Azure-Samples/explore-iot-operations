package counter

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

const (
	name        = "name"
	label       = "label"
	invalid     = "{}|}]["
	invalidUTF8 = "\xc3\x28"
)

func TestSimpleCounterProvider(t *testing.T) {
	registry := prometheus.NewRegistry()

	counterProvider, err := New(registry)

	require.NoError(t, err)

	counterProvider.Cancel()
}

func TestCounterProviderWithInvalidName(t *testing.T) {
	registry := prometheus.NewRegistry()

	_, err := New(registry, func(cp *Provider) {
		cp.Name = invalid
	})

	require.Equal(t, &InvalidPrometheusCounterVecNameError{
		name: invalid,
	}, err)
}

func TestCounterProviderWithDuplicateNames(t *testing.T) {

	registry := prometheus.NewRegistry()

	counterProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	_, err = counterProvider.With(label)

	require.NoError(t, err)

	_, err = New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.Equal(t, (&InvalidPrometheusCounterVecNameError{
		name: name,
	}).Error(), err.Error())
}

func TestCounterWithLabel(t *testing.T) {

	registry := prometheus.NewRegistry()

	counterProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	counter, err := counterProvider.With(name)

	counter.Observe(0)
	counter.Cancel()

	require.NoError(t, err)
}

func TestCounterWithLabelError(t *testing.T) {

	registry := prometheus.NewRegistry()

	counterProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	_, err = counterProvider.With("")

	require.NoError(t, err)

	_, err = counterProvider.With(invalidUTF8)

	require.Equal(t, (&InvalidPrometheusCounterLabelError{
		name:  name,
		label: invalidUTF8,
	}).Error(), err.Error())
}