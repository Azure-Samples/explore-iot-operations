package mage

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/magefile/mage/sh"
	"github.com/princjef/mageutil/bintool"
	"github.com/princjef/mageutil/shellcmd"
)

var (
	linter = bintool.Must(bintool.New(
		"golangci-lint{{.BinExt}}",
		"1.55.2",
		"https://github.com/golangci/golangci-lint/releases/download/v{{.Version}}/golangci-lint-{{.Version}}-{{.GOOS}}-{{.GOARCH}}{{.ArchiveExt}}",
	))
	golines = bintool.Must(bintool.NewGo(
		"github.com/segmentio/golines",
		"v0.11.0",
	))
	documenter = bintool.Must(bintool.New(
		"gomarkdoc{{.BinExt}}",
		"0.4.1",
		"https://github.com/princjef/gomarkdoc/releases/download/v{{.Version}}/gomarkdoc_{{.Version}}_{{.GOOS}}_{{.GOARCH}}{{.ArchiveExt}}",
	))
)

func ensureFormatter() error {
	return golines.Ensure()
}

func ensureLinter() error {
	return linter.Ensure()
}

func ensureDocumenter() error {
	return documenter.Ensure()
}

func EnsureAllTools() error {
	if err := ensureFormatter(); err != nil {
		return err
	}

	if err := ensureLinter(); err != nil {
		return err
	}

	if err := ensureDocumenter(); err != nil {
		return err
	}

	return nil
}

func Format() error {
	if err := ensureFormatter(); err != nil {
		return err
	}

	return golines.Command("-m 80 --no-reformat-tags --base-formatter gofmt -w .").
		Run()
}

func Lint() error {
	if err := ensureLinter(); err != nil {
		return err
	}

	return linter.Command("run").Run()
}

func Doc() error {
	if err := ensureDocumenter(); err != nil {
		return err
	}

	return shellcmd.RunAll(
		documenter.Command("./lib/..."),
	)
}

// Clean clears the testing cache such that all tests are fully run again.
// Cleaning the test cache is recommended to avoid letting flaky tests into the toolbox.
func Clean() error {
	return sh.RunV("go", "clean", "-testcache")
}

// Cover runs tests and generates coverage profiles for all tests.
// The tests run in atomic mode and check for race conditions.
// UnitTestTimeoutMs specifies the maximum amount of time a unit test will be given before it is considered failed.
func Cover(unitTestTimeoutMs int) error {
	err := Clean()
	if err != nil {
		return err
	}

	err = sh.RunV(
		"go",
		"test",
		"-timeout",
		fmt.Sprintf("%dms", unitTestTimeoutMs),
		"-cover",
		"--coverprofile=cover.tmp.out",
		"-covermode=atomic",
		"-race",
		"./...",
	)
	if err != nil {
		return err
	}

	err = sh.RunV("bash", "-c", `cat cover.tmp.out | grep -v "pb.go" > coverage.out`)
	if err != nil {
		return err
	}

	return sh.RunV("go", "tool", "cover", "-func=coverage.out")
}

// Package is a subset of the structure returned by the go list tool.
type Package struct {
	TestGoFiles  []string `json:"TestGoFiles"`
	XTestGoFiles []string `json:"XTestGoFiles"`
	ImportPath   string   `json:"ImportPath"`
}

// EnsureTests ensures that every package besides those excluded via the "TestPackageExclusions" variable defined above must contain at least one test file.
// This ensures that coverage will be measured for all packages and forces the creation of test files for all new packages.
// TestPackageExclusions is a set of packages which are excluded from the check for at least one test file.
// This should only include the main package and any packages which only define types or constants.
func EnsureTests(importPathRoot string, testPackageExclusions map[string]any) error {
	res, err := sh.Output("go", "list", "-json", "./...")
	if err != nil {
		return err
	}

	dec := json.NewDecoder(strings.NewReader(res))

	var packages []Package
	for {
		var pack Package
		err := dec.Decode(&pack)
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		packages = append(packages, pack)
	}

	for _, pack := range packages {
		if _, ok := testPackageExclusions[strings.TrimPrefix(pack.ImportPath, importPathRoot)]; ok {
			continue
		}
		if len(pack.XTestGoFiles) < 1 && len(pack.TestGoFiles) < 1 {
			return &PackageMissingTestFileError{
				name: pack.ImportPath,
			}
		}
	}

	return nil
}

// Bench will run all benchmarking tests in the codebase, if any are present.
func Bench() error {
	return sh.RunV("go", "test", "-bench=.", "-benchmem", "./...")
}

// EvaluateCoverage takes a coverage file and evaluates the coverage of code block and overall app unit test coverage.
// If the coverage of any given block or the overall coverage of the application does not meet the above
// thresholds, an error will be returned. Otherwise a message describing coverage will be reported.
// ExpectedBlockCoverage describes the minimum expected test coverage of each code block.
// ExpectedOverallCoverage describes the minimum expected test coverage of the overall codebase.
func EvaluateCoverage(expectedBlockCoverage, expectedOverallCoverage float64) error {
	res, err := sh.Output(
		"go",
		"tool",
		"cover",
		"-func=coverage.out",
	)
	if err != nil {
		return err
	}

	lines := strings.Split(res, "\n")

	totalCoverage := &Coverage{}
	coverages := make([]*Coverage, len(lines)-1)

	for idx, line := range lines {
		components := strings.Fields(line)
		if len(components) != 3 {
			return fmt.Errorf(
				"invalid number of fields in coverage profile, please regenerate profile",
			)
		}
		percentage, err := strconv.ParseFloat(
			strings.Trim(components[2], "%"),
			64,
		)
		if err != nil {
			return err
		}

		if idx == len(lines)-1 {
			totalCoverage.percentage = percentage
			break
		}

		coverages[idx] = &Coverage{
			path:       components[0],
			name:       components[1],
			percentage: percentage,
			expected:   expectedBlockCoverage,
		}
	}

	for _, coverage := range coverages {
		if coverage.percentage < expectedBlockCoverage {
			return coverage
		}
	}

	if totalCoverage.percentage < expectedOverallCoverage {
		return &InadequateOverallCoverageError{
			percentage: totalCoverage.percentage,
			expected:   expectedOverallCoverage,
		}
	}

	fmt.Printf(
		"measured overall unit test coverage of %0.2f%%\n",
		totalCoverage.percentage,
	)

	return nil
}

func Build(proj string, path string) error {
	return sh.RunV("go", "build", "-o", proj, path)
}

func CI(
	importPathRoot string,
	testPackageExclusions map[string]any,
	unitTestTimeoutMs int,
	expectedBlockCoverage, expectedOverallCoverage float64,
) error {

	err := EnsureAllTools()
	if err != nil {
		return err
	}

	err = Lint()
	if err != nil {
		return err
	}

	err = Format()
	if err != nil {
		return err
	}

	err = EnsureTests(importPathRoot, testPackageExclusions)
	if err != nil {
		return err
	}

	err = Cover(unitTestTimeoutMs)
	if err != nil {
		return err
	}

	return EvaluateCoverage(expectedBlockCoverage, expectedOverallCoverage)
}
