// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package exporter

import (
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
)

type CustomHistogramProvider struct {
	provider Provider
	Name     string
	Help     string
	Start    int
	Width    int
	Logger   logger.Logger
}

func New(
	exporter Exporter,
	options ...func(*CustomHistogramProvider),
) (*CustomHistogramProvider, error) {
	provider := &CustomHistogramProvider{
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(provider)
	}

	histProv, err := exporter.RegisterHistogram(
		provider.Name,
		provider.Help,
		provider.Start,
		provider.Width,
	)
	if err != nil {
		return nil, err
	}

	provider.provider = histProv

	return provider, nil
}

func (provider *CustomHistogramProvider) Cancel() error {
	err := provider.provider.Export()
	if err != nil {
		provider.Logger.Level(logger.Error).
			With("error", err.Error()).
			Printf("could not export data to file")
		return err
	}

	return nil
}

func (provider *CustomHistogramProvider) With(
	label string,
) (registry.CancellableObservable, error) {
	return provider.provider.Label(Label(label)), nil
}
