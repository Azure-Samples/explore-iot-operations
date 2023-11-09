// Package site provides the implementation of the site component of the simulation framework.
package site

import "github.com/explore-iot-ops/samples/krill/components/registry"

type Site interface {
	Render() string
	registry.Observable
}

// Site is a representation of a place where many devices/clients may be present.
// It implements the observable interface, allowing for monitoring of all devices within a site.
type StaticSite struct {
	registry.Observable
	Name string
}

// New creates a new site, given an observable monitor.
// Optional parameters can be set through the option function.
func New(mon registry.Observable, options ...func(*StaticSite)) *StaticSite {
	site := &StaticSite{
		Observable: mon,
	}

	for _, option := range options {
		option(site)
	}

	return site
}

func (site *StaticSite) Render() string {
	return site.Name
}

type MockSite struct {
	OnRender func() string
	registry.Observable
}

func (site *MockSite) Render() string {
	return site.OnRender()
}
