package edge

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/composition"
	"github.com/stretchr/testify/require"
)

const (
	MockID                        = "MockID"
	MockParentNodeID              = "MockParentNodeID"
	MockChildNodeID               = "MockChildNodeID"
	MockLabelEdgeConfiguration    = "MockLabelEdgeConfiguration"
	MockPositionEdgeConfiguration = 5
	MockInvalidType               = "MockInvalidType"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[composition.Edge, component.ID])
	require.True(t, ok)
}

func TestEdgeServiceLabel(t *testing.T) {
	service := NewService(&component.MockStore[composition.Edge, component.ID]{
		OnCreate: func(entity composition.Edge, identifier component.ID) error {
			return nil
		},
	}, &component.MockStore[composition.Renderer, component.ID]{
		OnGet: func(identifier component.ID) (composition.Renderer, error) {
			if identifier == MockParentNodeID {
				return &composition.MockNode{
					OnWith: func(e composition.Edge) composition.Node {
						res, ok := e.(*composition.Label)
						require.True(t, ok)
						require.Equal(t, MockLabelEdgeConfiguration, res.Edge())
						return nil
					},
				}, nil
			} else {
				require.Equal(t, MockChildNodeID, string(identifier))
			}
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		ParentNodeId:  MockParentNodeID,
		ChildNodeId:   MockChildNodeID,
		Type:          LABEL,
		Configuration: MockLabelEdgeConfiguration,
	})
	require.NoError(t, err)
}

func TestEdgeServicePosition(t *testing.T) {
	service := NewService(&component.MockStore[composition.Edge, component.ID]{
		OnCreate: func(entity composition.Edge, identifier component.ID) error {
			return nil
		},
	}, &component.MockStore[composition.Renderer, component.ID]{
		OnGet: func(identifier component.ID) (composition.Renderer, error) {
			if identifier == MockParentNodeID {
				return &composition.MockNode{
					OnWith: func(e composition.Edge) composition.Node {
						res, ok := e.(*composition.Position)
						require.True(t, ok)
						require.Equal(
							t,
							MockPositionEdgeConfiguration,
							res.Edge(),
						)
						return nil
					},
				}, nil
			} else {
				require.Equal(t, MockChildNodeID, string(identifier))
			}
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		ParentNodeId:  MockParentNodeID,
		ChildNodeId:   MockChildNodeID,
		Type:          POSITION,
		Configuration: MockPositionEdgeConfiguration,
	})
	require.NoError(t, err)
}

func TestEdgeServiceInvalidEdgeType(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return &composition.MockNode{}, nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId: MockParentNodeID,
		Type:         MockInvalidType,
	})
	require.Equal(t, &InvalidTypeError{
		kind:       MockInvalidType,
		identifier: MockID,
	}, err)
}

func TestEdgeServiceIdentifierConflict(t *testing.T) {
	service := NewService(nil, nil)

	err := service.Create(MockID, &Component{
		ParentNodeId: MockParentNodeID,
		ChildNodeId:  MockParentNodeID,
		Type:         MockInvalidType,
	})
	require.Equal(t, &IdentifierConflictError{
		invalid:    MockParentNodeID,
		identifier: MockID,
	}, err)
}

func TestEdgeServiceParentNodeStoreGetError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId: MockParentNodeID,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestEdgeServiceChildNodeStoreGetError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				if identifier == MockParentNodeID {
					return &composition.MockNode{}, nil
				}
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId: MockParentNodeID,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestEdgeServiceInvalidParentNodeType(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return &composition.MockRenderer{}, nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId: MockParentNodeID,
	})
	require.Equal(t, &InvalidParentNodeTypeError{
		identifier:           MockID,
		parentNodeIdentifier: MockParentNodeID,
	}, err)
}

func TestEdgeServiceInvalidLabelConfiguration(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return &composition.MockNode{}, nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId:  MockParentNodeID,
		Configuration: MockPositionEdgeConfiguration,
		Type:          LABEL,
	})
	require.Equal(t, &InvalidLabelError{
		identifier: MockID,
	}, err)
}

func TestEdgeServiceInvalidPositionConfiguration(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return &composition.MockNode{}, nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		ParentNodeId:  MockParentNodeID,
		Configuration: MockLabelEdgeConfiguration,
		Type:          POSITION,
	})
	require.Equal(t, &InvalidPositionError{
		identifier: MockID,
	}, err)
}
