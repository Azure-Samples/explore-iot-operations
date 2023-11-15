// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package exporter

import (
	"io"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
)

type MockExporter struct {
	OnRegisterHistogram func(name, help string, start, width int) (Provider, error)
}

func (exporter *MockExporter) RegisterHistogram(
	name, help string,
	start, width int,
) (Provider, error) {
	return exporter.OnRegisterHistogram(name, help, start, width)
}

type MockOpener struct {
	OnOpen func(filename string) (io.WriteCloser, error)
}

func (opener *MockOpener) Open(filename string) (io.WriteCloser, error) {
	return opener.OnOpen(filename)
}

type MockFile struct {
	OnWrite func(p []byte) (n int, err error)
	OnClose func() error
}

func (file *MockFile) Write(p []byte) (n int, err error) {
	return file.OnWrite(p)
}

func (file *MockFile) Close() error {
	return file.OnClose()
}

type MockProvider struct {
	OnExport func() error
	OnLabel  func(label Label) registry.CancellableObservable
}

func (provider *MockProvider) Export() error {
	return provider.OnExport()
}

func (provider *MockProvider) Label(
	label Label,
) registry.CancellableObservable {
	return provider.OnLabel(label)
}
