// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package exporter

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
)

type Exporter interface {
	RegisterHistogram(name, help string, start, width int) (Provider, error)
}

type Provider interface {
	Export() error
	Label(label Label) registry.CancellableObservable
}

type (
	Label string
	Kind  string
)

const (
	HISTOGRAM Kind = "histogram"
	COUNTER   Kind = "counter"
)

type HistogramOptions struct {
	Start int `json:"start"`
	Width int `json:"width"`
}

type HistogramProvider struct {
	file    io.WriteCloser
	mu      sync.Mutex
	Marshal func(v any) ([]byte, error)

	Name    string                `json:"name"`
	Help    string                `json:"help"`
	Kind    Kind                  `json:"kind"`
	Options HistogramOptions      `json:"options"`
	Data    map[Label]map[int]int `json:"data"`
}

func (provider *HistogramProvider) Export() error {
	provider.mu.Lock()
	defer provider.mu.Unlock()

	content, err := provider.Marshal(provider)
	if err != nil {
		return err
	}

	_, err = provider.file.Write(content)
	if err != nil {
		return err
	}

	return provider.file.Close()
}

func (provider *HistogramProvider) Label(
	label Label,
) registry.CancellableObservable {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	histogram := &Histogram{
		Data:    make(map[int]int),
		options: provider.Options,
	}
	provider.Data[label] = histogram.Data

	return histogram
}

type Histogram struct {
	mu      sync.Mutex
	options HistogramOptions
	Data    map[int]int `json:"data"`
}

func (histogram *Histogram) Observe(value float64) {
	histogram.mu.Lock()
	defer histogram.mu.Unlock()

	histogram.Data[(int(math.Floor(value))-histogram.options.Start)/histogram.options.Width]++
}

func (histogram *Histogram) Cancel() {}

type Opener interface {
	Open(filename string) (io.WriteCloser, error)
}

type FileExporter struct {
	opener Opener
}

func NewExporter(opener Opener) *FileExporter {
	return &FileExporter{
		opener: opener,
	}
}

func (exporter *FileExporter) RegisterHistogram(
	name, help string,
	start, width int,
) (Provider, error) {

	now := time.Now()
	f, err := exporter.opener.Open(
		fmt.Sprintf(
			"D%s-T%d-%d-%d-histogram-%s.json",
			now.Format(time.DateOnly),
			now.Hour(),
			now.Minute(),
			now.Second(),
			name,
		),
	)
	if err != nil {
		return nil, err
	}

	return &HistogramProvider{
		file:    f,
		Name:    name,
		Kind:    HISTOGRAM,
		Help:    help,
		Marshal: json.Marshal,
		Options: HistogramOptions{
			Start: start,
			Width: width,
		},
		Data: make(map[Label]map[int]int),
	}, nil
}

type FileOpener struct {
	storage  string
	OpenFile func(name string, flag int, perm fs.FileMode) (*os.File, error)
}

func NewOpener(storage string, options ...func(*FileOpener)) *FileOpener {
	opener := &FileOpener{
		storage:  storage,
		OpenFile: os.OpenFile,
	}

	for _, option := range options {
		option(opener)
	}

	return opener
}

func (fileOpener *FileOpener) Open(filename string) (io.WriteCloser, error) {
	return fileOpener.OpenFile(
		filepath.Join(fileOpener.storage, filename),
		os.O_RDWR|os.O_CREATE,
		0o0755,
	)
}
