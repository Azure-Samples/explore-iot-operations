// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package exporter

import (
	"io"
	"io/fs"
	"os"
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/stretchr/testify/require"
)

const (
	MockLabel = "MockLabel"
)

var (
	MockContent = []byte{0, 1}
)

type MockError struct{}

func (*MockError) Error() string {
	return "mock"
}

func TestMain(m *testing.M) {
	m.Run()
}

func TestHistogram(t *testing.T) {
	exporter := NewExporter(&MockOpener{
		OnOpen: func(string) (io.WriteCloser, error) {
			return nil, nil
		},
	})

	provider, err := exporter.RegisterHistogram("", "", 0, 10)
	require.NoError(t, err)

	histProvider, ok := provider.(*HistogramProvider)
	require.True(t, ok)

	histogram := provider.Label("")

	histogram.Observe(20)

	require.Equal(t, 1, histProvider.Data[""][2])

	histogram.Observe(19)

	require.Equal(t, 1, histProvider.Data[""][1])
}

func TestHistogramNonZeroStart(t *testing.T) {
	exporter := NewExporter(&MockOpener{
		OnOpen: func(string) (io.WriteCloser, error) {
			return nil, nil
		},
	})

	provider, err := exporter.RegisterHistogram("", "", 10, 10)
	require.NoError(t, err)

	histProvider, ok := provider.(*HistogramProvider)
	require.True(t, ok)

	histogram := provider.Label("")

	histogram.Observe(20)

	require.Equal(t, 1, histProvider.Data[""][1])

	histogram.Observe(19)

	require.Equal(t, 1, histProvider.Data[""][0])
}

func TestOpenerError(t *testing.T) {
	exporter := NewExporter(&MockOpener{
		OnOpen: func(string) (io.WriteCloser, error) {
			return nil, &MockError{}
		},
	})
	_, err := exporter.RegisterHistogram("", "", 0, 0)
	require.Equal(t, &MockError{}, err)
}

func TestFileOpener(t *testing.T) {
	opener := NewOpener("", func(fo *FileOpener) {
		fo.OpenFile = func(name string, flag int, perm fs.FileMode) (*os.File, error) {
			return nil, nil
		}
	})

	_, err := opener.Open("")
	require.NoError(t, err)
}

func TestMockExporter(t *testing.T) {
	exporter := &MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (Provider, error) {
			return nil, nil
		},
	}

	_, err := exporter.RegisterHistogram("", "", 0, 0)
	require.NoError(t, err)
}

func TestHistogramProvider(t *testing.T) {
	provider := &HistogramProvider{
		file: &MockFile{
			OnWrite: func(p []byte) (n int, err error) {
				require.Equal(t, MockContent, p)
				return 0, nil
			}, OnClose: func() error {
				return nil
			},
		}, Marshal: func(v any) ([]byte, error) {
			return MockContent, nil
		},
	}

	require.NoError(t, provider.Export())
}

func TestHistogramProviderMarshalError(t *testing.T) {
	provider := &HistogramProvider{
		file: &MockFile{
			OnWrite: func(p []byte) (n int, err error) {
				return 0, nil
			}, OnClose: func() error {
				return nil
			},
		}, Marshal: func(v any) ([]byte, error) {
			return nil, &MockError{}
		},
	}

	require.Equal(t, &MockError{}, provider.Export())
}

func TestHistogramProviderFileWriteError(t *testing.T) {
	provider := &HistogramProvider{
		file: &MockFile{
			OnWrite: func(p []byte) (n int, err error) {
				return 0, &MockError{}
			}, OnClose: func() error {
				return nil
			},
		}, Marshal: func(v any) ([]byte, error) {
			return nil, nil
		},
	}

	require.Equal(t, &MockError{}, provider.Export())
}

func TestCustomHistogramProvider(t *testing.T) {
	provider, err := New(&MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (Provider, error) {
			return &MockProvider{
				OnExport: func() error {
					return nil
				}, OnLabel: func(label Label) registry.CancellableObservable {
					require.Equal(t, MockLabel, string(label))
					return nil
				},
			}, nil
		},
	}, func(chp *CustomHistogramProvider) {
		chp.Logger = &logger.NoopLogger{}
	})
	require.NoError(t, err)

	_, err = provider.With(MockLabel)
	require.NoError(t, err)
}

func TestCustomHistogramProviderCancelError(t *testing.T) {
	provider, err := New(&MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (Provider, error) {
			return &MockProvider{
				OnExport: func() error {
					return &MockError{}
				}, OnLabel: func(label Label) registry.CancellableObservable {
					return nil
				},
			}, nil
		},
	}, func(chp *CustomHistogramProvider) {
		chp.Logger = &logger.MockLogger{
			OnLevel: func(i int) logger.Logger {
				require.Equal(t, logger.Error, i)
				return chp.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				require.Equal(t, "error", s1)
				require.Equal(t, (&MockError{}).Error(), s2)
				return chp.Logger
			}, OnPrintf: func(s string, i ...interface{}) {
				require.Equal(t, "could not export data to file", s)
			},
		}
	})
	require.NoError(t, err)

	require.Equal(t, &MockError{}, provider.Cancel())
}

func TestCustomHistogramProviderRegistrationError(t *testing.T) {
	_, err := New(&MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (Provider, error) {
			return nil, &MockError{}
		},
	})
	require.Equal(t, &MockError{}, err)
}

func TestStat(t *testing.T) {
	err := Stat(".")
	require.NoError(t, err)
}

func TestStatInvalidVolumeError(t *testing.T) {
	err := Stat("")
	require.Equal(t, (&InvalidVolumePath{}).Error(), err.Error())
}

func TestStatError(t *testing.T) {
	err := Stat("\u0000")
	require.Error(t, err)
	_, ok := err.(*InvalidVolumePath)
	require.False(t, ok)
}
