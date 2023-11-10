package gauge

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

func TestSimpleGaugeProvider(t *testing.T) {
	registry := prometheus.NewRegistry()

	gaugeProvider, err := New(registry)

	require.NoError(t, err)

	err = gaugeProvider.Cancel()
	require.NoError(t, err)
}

func TestGaugeProviderWithInvalidName(t *testing.T) {
	registry := prometheus.NewRegistry()

	_, err := New(registry, func(cp *Provider) {
		cp.Name = invalid
	})

	require.Equal(t, &InvalidPrometheusGaugeVecNameError{
		name: invalid,
	}, err)
}

func TestGaugeProviderWithDuplicateNames(t *testing.T) {

	registry := prometheus.NewRegistry()

	gaugeProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	_, err = gaugeProvider.With(label)

	require.NoError(t, err)

	_, err = New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.Equal(t, (&InvalidPrometheusGaugeVecNameError{
		name: name,
	}).Error(), err.Error())
}

func TestGaugeWithLabel(t *testing.T) {

	registry := prometheus.NewRegistry()

	gaugeProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	gauge, err := gaugeProvider.With(name)

	gauge.Observe(0)
	gauge.Cancel()

	require.NoError(t, err)
}

func TestGaugeWithLabelError(t *testing.T) {

	registry := prometheus.NewRegistry()

	gaugeProvider, err := New(registry, func(cp *Provider) {
		cp.Name = name
	})

	require.NoError(t, err)

	_, err = gaugeProvider.With("")

	require.NoError(t, err)

	_, err = gaugeProvider.With(invalidUTF8)

	require.Equal(t, (&InvalidPrometheusGaugeLabelError{
		name:  name,
		label: invalidUTF8,
	}).Error(), err.Error())
}
