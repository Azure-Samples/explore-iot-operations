package logger

import (
	"testing"

	"github.com/rs/zerolog/log"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestZeroLoggerWrapper(t *testing.T) {
	wrappedLogger := NewZeroLoggerWrapper(log.With().Logger())
	wrappedLogger.Printf("")
	wrappedLogger.Println("")
}

func TestNoopLogger(t *testing.T) {
	logger := &NoopLogger{}
	logger.Printf("")
	logger.Println("")
	logger.With("", "")
	logger.Level(0)
}

func TestMockLogger(t *testing.T) {
	logger := &MockLogger{
		OnPrintln: func(...interface{}) {
		},
		OnPrintf: func(string, ...interface{}) {
		},
		OnLevel: func(int) Logger {
			return nil
		},
		OnWith: func(string, string) Logger {
			return nil
		},
	}
	logger.Printf("")
	logger.Println("")
	logger.With("", "")
	logger.Level(0)
}