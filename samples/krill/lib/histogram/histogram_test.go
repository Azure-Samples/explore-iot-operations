package histogram

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

func TestSimpleHistogramProvider(t *testing.T) {
	registry := prometheus.NewRegistry()

	histogramProvider, err := New(registry)

	require.NoError(t, err)

	err = histogramProvider.Cancel()
	require.NoError(t, err)
}

func TestHistogramProviderWithLabel(t *testing.T) {
	registry := prometheus.NewRegistry()

	histogramProvider, err := New(registry, func(hp *Provider) {
		hp.Name = name
	})

	require.NoError(t, err)

	histogram, err := histogramProvider.With(label)

	histogram.Observe(0)
	histogram.Cancel()

	require.NoError(t, err)
}

func TestHistogramProviderWithInvalidName(t *testing.T) {
	registry := prometheus.NewRegistry()

	_, err := New(registry, func(hp *Provider) {
		hp.Name = invalid
	})

	require.Equal(t, InvalidPrometheusHistogramVecNameError{
		name: invalid,
	}, *err.(*InvalidPrometheusHistogramVecNameError))
}

func TestHistogramProviderWithInvalidBuckets(t *testing.T) {
	registry := prometheus.NewRegistry()
	buckets := -1

	_, err := New(registry, func(hp *Provider) {
		hp.Buckets = buckets
		hp.Name = name

	})

	require.Equal(t, &InvalidHistogramParametersError{
		buckets: buckets,
		name:    name,
	}, err)
}

func TestHistogramWithDuplicateNames(t *testing.T) {
	registry := prometheus.NewRegistry()

	_, err := New(registry, func(hp *Provider) {
		hp.Name = name
	})

	require.NoError(t, err)

	_, err = New(registry, func(hp *Provider) {
		hp.Name = name
	})

	require.Equal(t, &InvalidPrometheusHistogramVecNameError{
		name: name,
	}, err)
}

func TestHistogramWithInvalidLabelName(t *testing.T) {

	registry := prometheus.NewRegistry()

	histogramProvider, err := New(registry, func(hp *Provider) {
		hp.Name = name
	})

	require.NoError(t, err)

	_, err = histogramProvider.With(invalidUTF8)

	require.Equal(t, &InvalidPrometheusHistogramLabelError{
		name:  name,
		label: invalidUTF8,
	}, err)
}
