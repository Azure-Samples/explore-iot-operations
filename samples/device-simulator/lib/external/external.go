// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package external

import (
	"errors"
	"fmt"
	"io"

	"github.com/explore-iot-ops/samples/device-simulator/components/broker"
	"github.com/explore-iot-ops/samples/device-simulator/components/client"
	"github.com/explore-iot-ops/samples/device-simulator/components/edge"
	"github.com/explore-iot-ops/samples/device-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/device-simulator/components/limiter"
	"github.com/explore-iot-ops/samples/device-simulator/components/node"
	"github.com/explore-iot-ops/samples/device-simulator/components/observer"
	"github.com/explore-iot-ops/samples/device-simulator/components/outlet"
	"github.com/explore-iot-ops/samples/device-simulator/components/provider"
	"github.com/explore-iot-ops/samples/device-simulator/components/publisher"
	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/explore-iot-ops/samples/device-simulator/components/renderer"
	"github.com/explore-iot-ops/samples/device-simulator/components/site"
	"github.com/explore-iot-ops/samples/device-simulator/components/subscriber"
	"github.com/explore-iot-ops/samples/device-simulator/components/topic"
	"github.com/explore-iot-ops/samples/device-simulator/components/tracer"
	"github.com/explore-iot-ops/samples/device-simulator/lib/component"
	"github.com/explore-iot-ops/samples/device-simulator/lib/templater"
)

type DeviceSimulatorBuilder struct {
	brokerService     component.Service[*broker.Component, component.ID]
	clientService     component.Service[*client.Component, component.ID]
	edgeService       component.Service[*edge.Component, component.ID]
	formatterService  component.Service[*formatter.Component, component.ID]
	limiterService    component.Service[*limiter.Component, component.ID]
	nodeService       component.Service[*node.Component, component.ID]
	observerService   component.Service[*observer.Component, component.ID]
	outletService     component.Service[*outlet.Component, component.ID]
	providerService   component.Service[*provider.Component, component.ID]
	publisherService  component.Service[*publisher.Component, component.ID]
	registryService   component.Service[*registry.Component, component.ID]
	rendererService   component.Service[*renderer.Component, component.ID]
	siteService       component.Service[*site.Component, component.ID]
	subscriberService component.Service[*subscriber.Component, component.ID]
	topicService      component.Service[*topic.Component, component.ID]
	tracerService     component.Service[*tracer.Component, component.ID]
}

func New(
	brokerService component.Service[*broker.Component, component.ID],
	clientService component.Service[*client.Component, component.ID],
	edgeService component.Service[*edge.Component, component.ID],
	formatterService component.Service[*formatter.Component, component.ID],
	limiterService component.Service[*limiter.Component, component.ID],
	nodeService component.Service[*node.Component, component.ID],
	observerService component.Service[*observer.Component, component.ID],
	outletService component.Service[*outlet.Component, component.ID],
	providerService component.Service[*provider.Component, component.ID],
	publisherService component.Service[*publisher.Component, component.ID],
	registryService component.Service[*registry.Component, component.ID],
	rendererService component.Service[*renderer.Component, component.ID],
	siteService component.Service[*site.Component, component.ID],
	subscriberService component.Service[*subscriber.Component, component.ID],
	topicService component.Service[*topic.Component, component.ID],
	tracerService component.Service[*tracer.Component, component.ID],
) *DeviceSimulatorBuilder {
	return &DeviceSimulatorBuilder{
		brokerService:     brokerService,
		clientService:     clientService,
		edgeService:       edgeService,
		formatterService:  formatterService,
		limiterService:    limiterService,
		nodeService:       nodeService,
		observerService:   observerService,
		outletService:     outletService,
		providerService:   providerService,
		publisherService:  publisherService,
		registryService:   registryService,
		rendererService:   rendererService,
		siteService:       siteService,
		subscriberService: subscriberService,
		topicService:      topicService,
		tracerService:     tracerService,
	}
}

func (builder *DeviceSimulatorBuilder) Parse(configuration Simulation) error {
	err := builder.brokerService.Create(BrokerID, &broker.Component{
		Broker: configuration.Target.Host,
		Port:   configuration.Target.Port,
	})
	if err != nil {
		return err
	}

	for _, site := range configuration.Sites {
		err := builder.ParseSite(site)
		if err != nil {
			return err
		}
	}

	return nil
}

func (builder *DeviceSimulatorBuilder) ParseSite(configuration Site) error {
	err := builder.siteService.Create(
		component.ID(configuration.Name),
		&site.Component{
			Name: configuration.Name,
		},
	)
	if err != nil {
		return err
	}

	tags, err := builder.ParseTags(configuration)
	if err != nil {
		return err
	}

	err = builder.providerService.Create(
		component.ID(configuration.Name),
		&provider.Component{
			Type: provider.COUNTER,
			Name: fmt.Sprintf(ProviderIDFormat, configuration.Name),
		},
	)
	if err != nil {
		return err
	}

	assets, err := builder.ParseAssets(configuration)
	if err != nil {
		return err
	}

	err = builder.ParseTopics(configuration, tags, assets)
	if err != nil {
		return err
	}

	return nil
}

func (builder *DeviceSimulatorBuilder) ParseTopics(
	configuration Site,
	tags []string,
	assets []string,
) error {
	templateExecutor, err := templater.NewExecutor(configuration.TopicFormat)
	if err != nil {
		return err
	}

	topicTemplate := templater.New[TopicTemplate](templateExecutor)

	for _, asset := range assets {
		for _, tag := range tags {
			topicID := fmt.Sprintf(
				TopicIDFormat,
				configuration.Name,
				asset,
				tag,
			)

			reader, err := topicTemplate.Render(TopicTemplate{
				SiteName:  configuration.Name,
				AssetName: asset,
				TagName:   tag,
			})
			if err != nil {
				return err
			}

			res, err := io.ReadAll(reader)
			if err != nil {
				return err
			}

			err = builder.ParseTopicAndPublisher(
				configuration,
				topicID,
				string(res),
				asset,
				tag,
			)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

func (builder *DeviceSimulatorBuilder) ParseTopicAndPublisher(
	configuration Site,
	id string,
	name string,
	asset string,
	tag string,
) error {
	err := builder.topicService.Create(component.ID(id), &topic.Component{
		Name: name,
	})
	if err != nil {
		return err
	}

	err = builder.limiterService.Create(component.ID(id), &limiter.Component{
		Limit:         configuration.Rate.MessagesPerPeriod,
		PeriodSeconds: configuration.Rate.PeriodSeconds,
	})
	if err != nil {
		return err
	}

	return builder.publisherService.Create(
		component.ID(id),
		&publisher.Component{
			TopicID:           component.ID(id),
			ClientID:          component.ID(asset),
			RendererID:        component.ID(tag),
			QoSLevel:          configuration.QoSLevel,
			LimiterID:         component.ID(id),
			RendersPerPublish: configuration.Rate.TagsPerMessage,
		},
	)
}

func (builder *DeviceSimulatorBuilder) ParseTags(configuration Site) ([]string, error) {
	switch configuration.PayloadFormat {
	case "JSONTagPerMessage":
		return builder.ParseJSONTagPerMessage(configuration)
	case "JSON":
		return builder.ParseComplex(configuration, formatter.JSON)
	case "OPCUA":
		return builder.ParseOPCUA(configuration)
	case "BigEndian":
		return builder.ParseFlat(configuration, "bigEndian")
	case "LittleEndian":
		return builder.ParseFlat(configuration, "littleEndian")
	case "CSV":
		return builder.ParseComplex(configuration, formatter.CSV)
	case "Protobuf":
		return builder.ParseComplex(configuration, formatter.PROTOBUF)
	default:
		return nil, errors.New("invalid payload format")
	}
}

func (builder *DeviceSimulatorBuilder) ParseAssets(configuration Site) ([]string, error) {
	assets := make([]string, configuration.AssetCount)
	for count := 0; count < configuration.AssetCount; count++ {
		asset, err := builder.ParseAsset(configuration, count)
		if err != nil {
			return nil, err
		}
		assets[count] = asset
	}

	return assets, nil
}

func (builder *DeviceSimulatorBuilder) ParseAsset(
	configuration Site,
	count int,
) (string, error) {
	clientID := fmt.Sprintf(ClientIDFormat, configuration.Name, count)

	err := builder.registryService.Create(
		component.ID(clientID),
		&registry.Component{},
	)
	if err != nil {
		return "", err
	}

	err = builder.observerService.Create(
		component.ID(clientID),
		&observer.Component{
			RegistryID: component.ID(clientID),
			ProviderID: component.ID(configuration.Name),
			Label:      clientID,
		},
	)
	if err != nil {
		return "", err
	}

	err = builder.clientService.Create(
		component.ID(clientID),
		&client.Component{
			SiteID:     component.ID(configuration.Name),
			BrokerID:   BrokerID,
			Name:       clientID,
			Type:       client.Type(configuration.MQTTVersion),
			RegistryID: component.ID(clientID),
		},
	)
	if err != nil {
		return "", err
	}

	return clientID, nil
}

func (builder *DeviceSimulatorBuilder) ParseJSONTagPerMessage(
	configuration Site,
) ([]string, error) {
	err := builder.formatterService.Create(
		component.ID(configuration.Name),
		&formatter.Component{
			Type: formatter.JSON,
		},
	)
	if err != nil {
		return nil, err
	}

	var tagNames []string
	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			tagName, err := builder.ParseJSONTag(configuration.Name, tag, count)
			if err != nil {
				return nil, err
			}
			tagNames = append(tagNames, tagName)
		}
	}

	return tagNames, nil
}

func (builder *DeviceSimulatorBuilder) ParseJSONTag(
	siteName string,
	tag Tag,
	count int,
) (string, error) {
	tagID := fmt.Sprintf(TagIDFormat, siteName, tag.ID, count)
	childID := fmt.Sprintf(TagChildIDFormat, tagID)

	err := builder.ParseRootNode(siteName, tagID, node.COLLECTION)
	if err != nil {
		return "", err
	}

	err = builder.ParseExpressionNode(
		tagID,
		childID,
		tagID,
		tag.Configuration,
		tagID,
		edge.LABEL,
	)
	if err != nil {
		return "", err
	}

	return tagID, nil
}

func (builder *DeviceSimulatorBuilder) ParseOPCUA(configuration Site) ([]string, error) {
	err := builder.ParseFormatter(
		configuration.Name,
		formatter.JSON,
		node.COLLECTION,
	)
	if err != nil {
		return nil, err
	}

	timestampID := fmt.Sprintf(TagTimestampIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(
		configuration.Name,
		timestampID,
		timestampID,
		OPCUATimeExpression,
		OPCUATimeConfiguration,
		edge.LABEL,
	)
	if err != nil {
		return nil, err
	}

	sequenceID := fmt.Sprintf(TagSequenceIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(
		configuration.Name,
		sequenceID,
		sequenceID,
		OPCUASequenceExpression,
		OPCUASequenceConfiguration,
		edge.LABEL,
	)
	if err != nil {
		return nil, err
	}

	datasetWriterID := fmt.Sprintf(TagDatasetWriterIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(
		configuration.Name,
		datasetWriterID,
		datasetWriterID,
		OPCUADatasetWriterExpression,
		OPCUADatasetWriterConfiguration,
		edge.LABEL,
	)
	if err != nil {
		return nil, err
	}

	payloadID := fmt.Sprintf(TagPayloadIDFormat, configuration.Name)

	err = builder.ParseCollectionNode(
		configuration.Name,
		payloadID,
		payloadID,
		OPCUAPayloadConfiguration,
	)
	if err != nil {
		return nil, err
	}

	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			err := builder.ParseOPCUATag(configuration, payloadID, tag, count)
			if err != nil {
				return nil, err
			}
		}
	}

	return []string{configuration.Name}, nil
}

func (builder *DeviceSimulatorBuilder) ParseOPCUATag(
	configuration Site,
	rootId string,
	tag Tag,
	count int,
) error {
	tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

	err := builder.ParseCollectionNode(rootId, tagID, tagID, tagID)
	if err != nil {
		return err
	}

	valueID := fmt.Sprintf(TagValueIDFormat, tagID)

	err = builder.ParseExpressionNode(
		tagID,
		valueID,
		valueID,
		tag.Configuration,
		OPCUAValueConfiguration,
		edge.LABEL,
	)
	if err != nil {
		return err
	}

	sourceTimestampID := fmt.Sprintf(TagSourceTimestampIDFormat, tagID)

	return builder.ParseExpressionNode(
		tagID,
		sourceTimestampID,
		sourceTimestampID,
		OPCUASourceTimeExpression,
		OPCUASourceTimestampConfiguration,
		edge.LABEL,
	)
}

func (builder *DeviceSimulatorBuilder) ParseExpressionNode(
	rootNodeId, nodeId, edgeId, nodeExpression string,
	edgeConfiguration any,
	edgeType edge.Type,
) error {
	err := builder.nodeService.Create(component.ID(nodeId), &node.Component{
		Type:          node.EXPRESSION,
		Configuration: nodeExpression,
	})
	if err != nil {
		return err
	}

	return builder.edgeService.Create(component.ID(edgeId), &edge.Component{
		ParentNodeId:  component.ID(rootNodeId),
		ChildNodeId:   component.ID(nodeId),
		Type:          edgeType,
		Configuration: edgeConfiguration,
	})
}

func (builder *DeviceSimulatorBuilder) ParseCollectionNode(
	rootNodeId, nodeId, edgeId, edgeConfiguration string,
) error {
	err := builder.nodeService.Create(component.ID(nodeId), &node.Component{
		Type: node.COLLECTION,
	})
	if err != nil {
		return err
	}

	return builder.edgeService.Create(component.ID(edgeId), &edge.Component{
		ParentNodeId:  component.ID(rootNodeId),
		ChildNodeId:   component.ID(nodeId),
		Type:          edge.LABEL,
		Configuration: edgeConfiguration,
	})
}

func (builder *DeviceSimulatorBuilder) ParseComplex(
	configuration Site,
	format formatter.Type,
) ([]string, error) {
	err := builder.ParseFormatter(configuration.Name, format, node.COLLECTION)
	if err != nil {
		return nil, err
	}

	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

			err := builder.ParseExpressionNode(
				configuration.Name,
				tagID,
				tagID,
				tag.Configuration,
				tagID,
				edge.LABEL,
			)
			if err != nil {
				return nil, err
			}
		}
	}

	return []string{configuration.Name}, nil
}

func (builder *DeviceSimulatorBuilder) ParseFormatter(
	id string,
	format formatter.Type,
	nodeType node.Type,
) error {
	err := builder.formatterService.Create(
		component.ID(id),
		&formatter.Component{
			Type: format,
		},
	)
	if err != nil {
		return err
	}

	return builder.ParseRootNode(id, id, nodeType)
}

func (builder *DeviceSimulatorBuilder) ParseRootNode(
	formatterID string,
	id string,
	nodeType node.Type,
) error {
	err := builder.nodeService.Create(component.ID(id), &node.Component{
		Type: nodeType,
	})
	if err != nil {
		return err
	}

	return builder.rendererService.Create(component.ID(id), &renderer.Component{
		FormatterID: component.ID(formatterID),
		NodeID:      component.ID(id),
	})
}

func (builder *DeviceSimulatorBuilder) ParseFlat(
	configuration Site,
	format formatter.Type,
) ([]string, error) {

	err := builder.ParseFormatter(configuration.Name, format, node.ARRAY)
	if err != nil {
		return nil, err
	}

	field := 0
	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

			err := builder.ParseExpressionNode(
				configuration.Name,
				tagID,
				tagID,
				tag.Configuration,
				field,
				edge.POSITION,
			)
			if err != nil {
				return nil, err
			}

			field++
		}
	}

	return []string{configuration.Name}, nil
}
