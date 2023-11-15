// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package site

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestSite(t *testing.T) {
	site := New(nil)

	require.Equal(t, "", site.Name)
}
