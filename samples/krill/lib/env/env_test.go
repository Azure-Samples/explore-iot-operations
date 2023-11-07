package env

import (
	"flag"
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

const (
	MockSource            = "MockSource"
	MockConfigProperty    = "MockConfig"
	MockBoolFlagName      = "MockBoolFlagName"
	MockStringFlagName    = "MockStringFlagName"
	MockIntFlagName       = "MockIntFlagName"
	MockStringFlagDefault = "MockStringFlagDefault"
	MockBoolFlagDefault   = true
	MockIntFlagDefault    = 1
)

var (
	MockContent = []byte{0, 1}
)

type MockError struct{}

func (*MockError) Error() string {
	return "mock"
}

type MockConfig struct {
	Property string
}

var originalFlagSet flag.FlagSet

func TestMain(m *testing.M) {
	originalFlagSet = *flag.CommandLine
	m.Run()
}

func TestReadEnv(t *testing.T) {
	v := "test"
	err := os.Setenv(v, v)
	require.NoError(t, err)
	require.Equal(t, v, ReadEnv(v))
	ReadEnv(v)
}

func TestConfigurationReader(t *testing.T) {
	reader := New[MockConfig](func(cr *ConfigurationReader[MockConfig]) {
		cr.Unmarshal = func(data []byte, v any) error {
			require.Equal(t, MockContent, data)
			res, ok := v.(*MockConfig)
			require.True(t, ok)
			res.Property = MockConfigProperty
			return nil
		}
		cr.ReadFile = func(name string) ([]byte, error) {
			require.Equal(t, MockSource, name)
			return MockContent, nil
		}
	})

	res, err := reader.Read(MockSource)
	require.NoError(t, err)
	require.Equal(t, MockConfigProperty, res.Property)
}

func TestConfigurationReaderReadFileError(t *testing.T) {
	reader := New[MockConfig](func(cr *ConfigurationReader[MockConfig]) {
		cr.ReadFile = func(name string) ([]byte, error) {
			return nil, &MockError{}
		}
	})

	_, err := reader.Read(MockSource)
	require.Equal(t, (&CannotOpenConfigurationFileError{
		err: &MockError{},
	}).Error(), err.Error())
}

func TestConfigurationReaderUnmarshalError(t *testing.T) {
	reader := New[MockConfig](func(cr *ConfigurationReader[MockConfig]) {
		cr.ReadFile = func(name string) ([]byte, error) {
			return nil, nil
		}
		cr.Unmarshal = func(data []byte, v any) error {
			return &MockError{}
		}
	})

	_, err := reader.Read(MockSource)
	require.Equal(t, (&CannotParseFileContentError{
		err: &MockError{},
	}).Error(), err.Error())
}

func TestFlagParserBool(t *testing.T) {
	done := make(chan struct{})
	parser := NewFlagParser(func(fp *FlagParser) {
		fp.Parse = func() {
			close(done)
		}
		fp.ParseBool = func(name string, value bool, usage string) *bool {
			require.Equal(t, "", usage)
			require.Equal(t, MockBoolFlagName, name)
			require.Equal(t, MockBoolFlagDefault, value)
			return nil
		}
	})

	m, err := parser.ReadFlags(map[string]any{
		MockBoolFlagName: MockBoolFlagDefault,
	})
	require.NoError(t, err)
	require.Nil(t, m[MockBoolFlagName])

	<-done
}

func TestFlagParserInt(t *testing.T) {
	parser := NewFlagParser(func(fp *FlagParser) {
		fp.Parse = func() {}
		fp.ParseInt = func(name string, value int, usage string) *int {
			require.Equal(t, "", usage)
			require.Equal(t, MockIntFlagName, name)
			require.Equal(t, MockIntFlagDefault, value)
			return nil
		}
	})

	m, err := parser.ReadFlags(map[string]any{
		MockIntFlagName: MockIntFlagDefault,
	})
	require.NoError(t, err)
	require.Nil(t, m[MockIntFlagName])
}

func TestFlagParserString(t *testing.T) {
	parser := NewFlagParser(func(fp *FlagParser) {
		fp.Parse = func() {}
		fp.ParseString = func(name string, value string, usage string) *string {
			require.Equal(t, "", usage)
			require.Equal(t, MockStringFlagDefault, name)
			require.Equal(t, MockStringFlagDefault, value)
			return nil
		}
	})

	m, err := parser.ReadFlags(map[string]any{
		MockStringFlagDefault: MockStringFlagDefault,
	})
	require.NoError(t, err)
	require.Nil(t, m[MockStringFlagDefault])
}

func TestInvalidFlagTypeError(t *testing.T) {
	parser := NewFlagParser(func(fp *FlagParser) {})

	_, err := parser.ReadFlags(map[string]any{
		"": nil,
	})
	require.Equal(t, (&InvalidFlagTypeError{}).Error(), err.Error())
}
