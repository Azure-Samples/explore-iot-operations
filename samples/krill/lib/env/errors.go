package env

import "fmt"

type CannotOpenConfigurationFileError struct {
	err error
}

func (err *CannotOpenConfigurationFileError) Error() string {
	return fmt.Sprintf("the file at the provided path could not be opened: %q", err.err.Error())
}

type CannotParseFileContentError struct {
	err error
}

func (err *CannotParseFileContentError) Error() string {
	return fmt.Sprintf("the content of the specified file could not be parsed: %q", err.err.Error())
}

type InvalidFlagTypeError struct {}

func (*InvalidFlagTypeError) Error() string {
	return "flag default must be of type int, string, or bool"
}