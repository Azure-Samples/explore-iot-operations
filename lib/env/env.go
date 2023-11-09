package env

import (
	"flag"
	"os"
	"path"

	"gopkg.in/yaml.v3"
)

type UnmarshalFunc func(data []byte, v any) error

type ConfigurationReader[E any] struct {
	ReadFile  func(name string) ([]byte, error)
	Unmarshal UnmarshalFunc
}

func New[E any](options ...func(*ConfigurationReader[E])) *ConfigurationReader[E] {
	reader := &ConfigurationReader[E]{
		ReadFile:  os.ReadFile,
		Unmarshal: yaml.Unmarshal,
	}

	for _, option := range options {
		option(reader)
	}

	return reader
}

func (reader *ConfigurationReader[E]) Read(
	configSrc string,
) (E, error) {
	var config E

	content, err := reader.ReadFile(path.Clean(configSrc))
	if err != nil {
		return config, &CannotOpenConfigurationFileError{
			err: err,
		}
	}

	err = reader.Unmarshal(content, &config)
	if err != nil {
		return config, &CannotParseFileContentError{
			err: err,
		}
	}

	return config, err
}

func ReadEnv(key string) string {
	return os.Getenv(key)
}

type FlagParser struct {
	ParseInt    func(name string, value int, usage string) *int
	ParseString func(name string, value string, usage string) *string
	ParseBool   func(name string, value bool, usage string) *bool
	Parse       func()
}

func NewFlagParser(options ...func(*FlagParser)) *FlagParser {
	parser := &FlagParser{
		ParseInt:    flag.Int,
		ParseString: flag.String,
		ParseBool:   flag.Bool,
		Parse:       flag.Parse,
	}

	for _, option := range options {
		option(parser)
	}

	return parser
}

func (parser *FlagParser) ReadFlags(flags map[string]any) (map[string]any, error) {
	m := make(map[string]any)

	for f, t := range flags {
		switch def := t.(type) {
		case int:
			m[f] = parser.ParseInt(f, def, "")
		case string:
			m[f] = parser.ParseString(f, def, "")
		case bool:
			m[f] = parser.ParseBool(f, def, "")
		default:
			return nil, &InvalidFlagTypeError{}
		}
	}

	parser.Parse()

	return m, nil
}
