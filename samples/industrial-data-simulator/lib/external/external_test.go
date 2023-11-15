// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package external

import (
	"testing"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/edge"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/node"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/renderer"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/stretchr/testify/require"
)

var (
	MockDeviceSimulatorTag = Tag{
		ID:            "float_1",
		Configuration: "1",
		Count:         1,
		MissingChance: 0,
	}
	MockDeviceSimulatorRate = Rate{
		MessagesPerPeriod: 10,
		PeriodSeconds:     1,
		TagsPerMessage:    1,
	}
	MockDeviceSimulatorTarget = Target{
		Host: "localhost",
		Port: 1883,
	}
	MockDeviceSimulatorSite = Site{
		Name: "site0",
		Tags: []Tag{
			MockDeviceSimulatorTag,
		},
		AssetCount:    1,
		Rate:          MockDeviceSimulatorRate,
		PayloadFormat: "JSON",
		TopicFormat:   "{{.SiteName}}/{{.AssetName}}",
		QoSLevel:      1,
		MQTTVersion:   "v5",
	}
	MockDeviceSimulatorConfiguration = Simulation{
		Sites: []Site{
			MockDeviceSimulatorSite,
		},
		Target: MockDeviceSimulatorTarget,
	}
)

const (
	MockRootNodeID        = "MockRootID"
	MockChildNodeID       = "MockChildNodeID"
	MockEdgeID            = "MockEdgeID"
	MockNodeExpression    = "MockNodeExpression"
	MockEdgeConfiguration = "MockEdgeConfiguration"
	MockEdgeType          = edge.LABEL
	MockFormatterID       = "MockFormatterID"
	MockFormatterType     = formatter.BIG_ENDIAN
	MockSiteName          = "MockSiteName"
	MockTagID             = "MockTagID"
	MockTagConfiguration  = "MockTagConfiguration"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestParseExpressionNode(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				require.Equal(t, MockChildNodeID, string(identifier))
				require.Equal(t, node.EXPRESSION, entity.Type)
				require.Equal(t, MockNodeExpression, entity.Configuration)
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				require.Equal(t, MockEdgeID, string(identifier))
				require.Equal(t, MockRootNodeID, string(entity.ParentNodeId))
				require.Equal(t, MockChildNodeID, string(entity.ChildNodeId))
				require.Equal(t, MockEdgeType, entity.Type)
				require.Equal(t, MockEdgeConfiguration, entity.Configuration)
				return nil
			},
		},
	}

	err := builder.ParseExpressionNode(
		MockRootNodeID,
		MockChildNodeID,
		MockEdgeID,
		MockNodeExpression,
		MockEdgeConfiguration,
		MockEdgeType,
	)
	require.NoError(t, err)
}

func TestParseExpressionNodeNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return &component.MockError{}
			},
		},
	}

	err := builder.ParseExpressionNode("", "", "", "", "", "")
	require.Equal(t, &component.MockError{}, err)
}

func TestParseCollectionNode(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				require.Equal(t, MockChildNodeID, string(identifier))
				require.Equal(t, node.COLLECTION, entity.Type)
				require.Equal(t, "", entity.Configuration)
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				require.Equal(t, MockEdgeID, string(identifier))
				require.Equal(t, MockRootNodeID, string(entity.ParentNodeId))
				require.Equal(t, MockChildNodeID, string(entity.ChildNodeId))
				require.Equal(t, edge.LABEL, entity.Type)
				require.Equal(t, MockEdgeConfiguration, entity.Configuration)
				return nil
			},
		},
	}

	err := builder.ParseCollectionNode(
		MockRootNodeID,
		MockChildNodeID,
		MockEdgeID,
		MockEdgeConfiguration,
	)
	require.NoError(t, err)
}

func TestParseCollectionNodeNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return &component.MockError{}
			},
		},
	}

	err := builder.ParseCollectionNode("", "", "", "")
	require.Equal(t, &component.MockError{}, err)
}

func TestParseRootNode(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				require.Equal(t, MockRootNodeID, string(identifier))
				require.Equal(t, node.COLLECTION, entity.Type)
				require.Equal(t, "", entity.Configuration)
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				require.Equal(t, MockRootNodeID, string(identifier))
				require.Equal(t, MockFormatterID, string(entity.FormatterID))
				require.Equal(t, MockRootNodeID, string(entity.NodeID))
				return nil
			},
		},
	}

	err := builder.ParseRootNode(
		MockFormatterID,
		MockRootNodeID,
		node.COLLECTION,
	)
	require.NoError(t, err)
}

func TestParseRootNodeNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return &component.MockError{}
			},
		},
	}

	err := builder.ParseRootNode("", "", "")
	require.Equal(t, &component.MockError{}, err)
}

func TestParseFormatter(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				require.Equal(t, MockFormatterID, string(identifier))
				require.Equal(t, MockFormatterType, entity.Type)
				return nil
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	err := builder.ParseFormatter(MockFormatterID, MockFormatterType, "")
	require.NoError(t, err)
}

func TestParseFormatterError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				return &component.MockError{}
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	err := builder.ParseFormatter("", "", "")
	require.Equal(t, &component.MockError{}, err)
}

func TestParseFlat(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				require.Equal(t, MockFormatterType, entity.Type)
				require.Equal(t, MockSiteName, string(identifier))
				return nil
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	tags, err := builder.ParseFlat(Site{
		Name: MockSiteName,
		Tags: []Tag{
			{
				ID:            MockTagID,
				Configuration: MockTagConfiguration,
				Count:         1,
			},
		},
	}, MockFormatterType)
	require.NoError(t, err)
	require.Equal(t, []string{MockSiteName}, tags)
}

func TestParseFlatFormatterError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				return &component.MockError{}
			},
		},
	}

	_, err := builder.ParseFlat(Site{}, MockFormatterType)
	require.Equal(t, &component.MockError{}, err)
}

func TestParseFlatExpressionNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				return nil
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				return &component.MockError{}
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	_, err := builder.ParseFlat(Site{
		Name: MockSiteName,
		Tags: []Tag{
			{
				Count: 1,
			},
		},
	}, MockFormatterType)
	require.Equal(t, &component.MockError{}, err)
}

func TestParseJSONTag(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				require.Equal(
					t,
					"MockSiteName__MockTagID__0__child",
					string(entity.ChildNodeId),
				)
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	res, err := builder.ParseJSONTag(MockSiteName, Tag{
		Count: 1,
		ID:    MockTagID,
	}, 0)
	require.NoError(t, err)
	require.Equal(t, "MockSiteName__MockTagID__0", res)
}

func TestParseJSONTagRootNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return &component.MockError{}
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	_, err := builder.ParseJSONTag(MockSiteName, Tag{}, 0)
	require.Equal(t, &component.MockError{}, err)
}

func TestParseJSONTagExpressionNodeError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				return &component.MockError{}
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	_, err := builder.ParseJSONTag(MockSiteName, Tag{}, 0)
	require.Equal(t, &component.MockError{}, err)
}

func TestParseJSONTagPerMessage(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				require.Equal(t, MockSiteName, string(identifier))
				require.Equal(t, formatter.JSON, entity.Type)
				return nil
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return nil
			},
		}, edgeService: &component.MockService[*edge.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *edge.Component) error {
				return nil
			},
		}, rendererService: &component.MockService[*renderer.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *renderer.Component) error {
				return nil
			},
		},
	}

	tags, err := builder.ParseJSONTagPerMessage(Site{
		Name: MockSiteName,
		Tags: []Tag{
			{
				ID:    MockTagID,
				Count: 1,
			},
		},
	})
	require.NoError(t, err)
	require.Equal(t, []string{"MockSiteName__MockTagID__0"}, tags)
}

func TestParseJSONTagPerMessageFormatterError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				return &component.MockError{}
			},
		},
	}

	_, err := builder.ParseJSONTagPerMessage(Site{})
	require.Equal(t, &component.MockError{}, err)
}

func TestParseJSONTagPerMessageParseJSONTagError(t *testing.T) {
	builder := &DeviceSimulatorBuilder{
		formatterService: &component.MockService[*formatter.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *formatter.Component) error {
				return nil
			},
		},
		nodeService: &component.MockService[*node.Component, component.ID]{
			OnCreate: func(identifier component.ID, entity *node.Component) error {
				return &component.MockError{}
			},
		},
	}

	_, err := builder.ParseJSONTagPerMessage(Site{
		Name: MockSiteName,
		Tags: []Tag{
			{
				ID:    MockTagID,
				Count: 1,
			},
		},
	})
	require.Equal(t, &component.MockError{}, err)
}
