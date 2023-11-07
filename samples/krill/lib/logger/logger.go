// Package logger provides all logging functionality for the simulation framework.
package logger

import (
	"fmt"

	"github.com/rs/zerolog"
)

// Level provides the String function which converts an int-based level into a string representation.
type Level struct{}

const (
	Trace int = iota
	Debug
	Info
	Warn
	Critical
	Error
	Fatal
	Panic
)

const (
	levelName = "level"
)

// String converts a given integer level to a string representation.
// It is meant to be used with the iota enumeration defined above.
func (l *Level) String(level int) string {
	switch level {
	case Trace:
		return "trace"
	case Debug:
		return "debug"
	case Info:
		return "info"
	case Warn:
		return "warn"
	case Critical:
		return "critical"
	case Error:
		return "error"
	case Fatal:
		return "fatal"
	case Panic:
		return "panic"
	default:
		return "no_level_defined"
	}
}

// LevelString is an interface whose implementation should convert an integer based log level to a string.
type LevelString interface {
	String(int) string
}

// Logger is an interface whose implementation should be able to print logs and enrich these logs with level information and custom key-value pair fields.
type Logger interface {
	Println(v ...interface{})
	Printf(format string, v ...interface{})
	Level(l int) Logger
	With(k, v string) Logger
	Tag(t string) Logger
}

// ZeroLoggerWrapper is a Logger implementation which wraps the logging functionality of the zero-log library.
// It also uses a LevelString implementation to convert numerical log levels to strings which can be logged.
type ZeroLoggerWrapper struct {
	logger   zerolog.Logger
	Levels   LevelString
	LogLevel int
	Tags     string
}

// NewZeroLoggerWrapper creates a new ZeroLoggerWrapper given a zerolog logger.
// Optional parameters (LevelString implementation and LogLevel) can be set using the options function.
func NewZeroLoggerWrapper(
	logger zerolog.Logger,
	options ...func(*ZeroLoggerWrapper),
) *ZeroLoggerWrapper {
	wrapper := &ZeroLoggerWrapper{
		logger: logger,
		Levels: &Level{},
	}

	for _, option := range options {
		option(wrapper)
	}

	return wrapper
}

// Level creates a new ZeroLoggerWrapper whose logs will all contain the level field defined by the provided level.
// If the level is not above the originally specified log level, a noop logger will be returned.
func (loggerWrapper *ZeroLoggerWrapper) Level(l int) Logger {
	if l < loggerWrapper.LogLevel {
		return &NoopLogger{}
	}

	return &ZeroLoggerWrapper{
		logger: loggerWrapper.logger.With().
			Str(levelName, loggerWrapper.Levels.String(l)).
			Logger(),
		Levels:   loggerWrapper.Levels,
		LogLevel: loggerWrapper.LogLevel,
		Tags:     loggerWrapper.Tags,
	}
}

// With enriches the current logger with a new key value pair, and returns a new ZeroLoggerWrapper.
func (loggerWrapper *ZeroLoggerWrapper) With(k, v string) Logger {
	return &ZeroLoggerWrapper{
		logger:   loggerWrapper.logger.With().Str(k, v).Logger(),
		Levels:   loggerWrapper.Levels,
		LogLevel: loggerWrapper.LogLevel,
		Tags:     loggerWrapper.Tags,
	}
}

func (loggerWrapper *ZeroLoggerWrapper) Tag(t string) Logger {
	if loggerWrapper.Tags == "" {
		return &ZeroLoggerWrapper{
			logger:   loggerWrapper.logger,
			Levels:   loggerWrapper.Levels,
			LogLevel: loggerWrapper.LogLevel,
			Tags:     `"` + t + `"`,
		}
	}
	return &ZeroLoggerWrapper{
		logger:   loggerWrapper.logger,
		Levels:   loggerWrapper.Levels,
		LogLevel: loggerWrapper.LogLevel,
		Tags:     loggerWrapper.Tags + `,"` + t + `"`,
	}
}

// Printf converts a format string using Sprintf and then logs this as the message field in the zerolog logger.
func (loggerWrapper *ZeroLoggerWrapper) Printf(
	format string,
	v ...interface{},
) {
	loggerWrapper.logger.Log().RawJSON("tags", []byte("[" + loggerWrapper.Tags + "]")).Msg(fmt.Sprintf(format, v...))
}

// Println applies a Sprintln to provided parameters and then logs this as a message field in the zerolog logger.
func (loggerWrapper *ZeroLoggerWrapper) Println(v ...interface{}) {
	loggerWrapper.logger.Log().RawJSON("tags", []byte("[" + loggerWrapper.Tags + "]")).Msg(fmt.Sprintln(v...))
}

// NoopLogger is a Logger implementation with Noop functionality.
// From a performance perspective, it makes the most sense to perform logging this way,
// as the compiler will optimize noop function calls under the hood.
type NoopLogger struct {
}

// Println is a noop.
func (*NoopLogger) Println(...interface{}) {
}

// Printf is a noop.
func (*NoopLogger) Printf(string, ...interface{}) {
}

// Level returns the noop logger.
func (l *NoopLogger) Level(int) Logger {
	return l
}

// With returns the noop logger.
func (l *NoopLogger) With(string, string) Logger {
	return l
}

func (l *NoopLogger) Tag(t string) Logger {
	return l
}

// MockLogger is a mock logger implementation to be used in testing scenarios.
type MockLogger struct {
	OnPrintln func(...interface{})
	OnPrintf  func(string, ...interface{})
	OnLevel   func(int) Logger
	OnWith    func(string, string) Logger
	OnTag     func(string) Logger
}

// Println calls the mock logger's OnPrintln function, passing through its parameters.
func (l *MockLogger) Println(s ...interface{}) {
	l.OnPrintln(s...)
}

// Printf calls the mock logger's OnPrintf function, passing through its parameters.
func (l *MockLogger) Printf(s string, ls ...interface{}) {
	l.OnPrintf(s, ls...)
}

// Level calls the mock logger's OnLevel function, passing through its parameters.
func (l *MockLogger) Level(i int) Logger {
	return l.OnLevel(i)
}

// With calls the mock logger's OnWith function, passing through its parameters.
func (l *MockLogger) With(k string, v string) Logger {
	return l.OnWith(k, v)
}

func (l *MockLogger) Tag(t string) Logger {
	return l.OnTag(t)
}
