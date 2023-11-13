package mage

import "fmt"

// PackageMissingTestFileError is an error describing a package which is missing a test file.
type PackageMissingTestFileError struct {
	name string
}

func (err *PackageMissingTestFileError) Error() string {
	return fmt.Sprintf(
		"package %q is missing a test file and is not listed in the packages excluded from requiring a test file",
		err.name,
	)
}

type Coverage struct {
	path       string
	name       string
	percentage float64
	expected   float64
}

func (coverage *Coverage) Error() string {
	return fmt.Sprintf(
		"block %q in file %q has an inadequate unit test coverage percentage of %0.2f%% where %0.2f%% was expected",
		coverage.name,
		coverage.path,
		coverage.percentage,
		coverage.expected,
	)
}

type InadequateOverallCoverageError struct {
	percentage float64
	expected   float64
}

func (err *InadequateOverallCoverageError) Error() string {
	return fmt.Sprintf(
		"inadequate overall unit test coverage percentage of %0.2f%% where %0.2f%% was expected",
		err.percentage,
		err.expected,
	)
}
