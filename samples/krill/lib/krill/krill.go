package krill

import (
	"errors"
	"fmt"
	"io"

	"github.com/iot-for-all/device-simulation/components/broker"
	"github.com/iot-for-all/device-simulation/components/client"
	"github.com/iot-for-all/device-simulation/components/edge"
	"github.com/iot-for-all/device-simulation/components/formatter"
	"github.com/iot-for-all/device-simulation/components/limiter"
	"github.com/iot-for-all/device-simulation/components/node"
	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/outlet"
	"github.com/iot-for-all/device-simulation/components/provider"
	"github.com/iot-for-all/device-simulation/components/publisher"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/renderer"
	"github.com/iot-for-all/device-simulation/components/site"
	"github.com/iot-for-all/device-simulation/components/subscriber"
	"github.com/iot-for-all/device-simulation/components/topic"
	"github.com/iot-for-all/device-simulation/components/tracer"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/templater"
)

type KrillBuilder struct {
	broker     component.Service[*broker.Component, component.ID]
	client     component.Service[*client.Component, component.ID]
	edge       component.Service[*edge.Component, component.ID]
	formatter  component.Service[*formatter.Component, component.ID]
	limiter    component.Service[*limiter.Component, component.ID]
	node       component.Service[*node.Component, component.ID]
	observer   component.Service[*observer.Component, component.ID]
	outlet     component.Service[*outlet.Component, component.ID]
	provider   component.Service[*provider.Component, component.ID]
	publisher  component.Service[*publisher.Component, component.ID]
	registry   component.Service[*registry.Component, component.ID]
	renderer   component.Service[*renderer.Component, component.ID]
	site       component.Service[*site.Component, component.ID]
	subscriber component.Service[*subscriber.Component, component.ID]
	topic      component.Service[*topic.Component, component.ID]
	tracer     component.Service[*tracer.Component, component.ID]
}

func New(
	broker component.Service[*broker.Component, component.ID],
	client component.Service[*client.Component, component.ID],
	edge component.Service[*edge.Component, component.ID],
	formatter component.Service[*formatter.Component, component.ID],
	limiter component.Service[*limiter.Component, component.ID],
	node component.Service[*node.Component, component.ID],
	observer component.Service[*observer.Component, component.ID],
	outlet component.Service[*outlet.Component, component.ID],
	provider component.Service[*provider.Component, component.ID],
	publisher component.Service[*publisher.Component, component.ID],
	registry component.Service[*registry.Component, component.ID],
	renderer component.Service[*renderer.Component, component.ID],
	site component.Service[*site.Component, component.ID],
	subscriber component.Service[*subscriber.Component, component.ID],
	topic component.Service[*topic.Component, component.ID],
	tracer component.Service[*tracer.Component, component.ID],
) *KrillBuilder {
	return &KrillBuilder{
		broker:     broker,
		client:     client,
		edge:       edge,
		formatter:  formatter,
		limiter:    limiter,
		node:       node,
		observer:   observer,
		outlet:     outlet,
		provider:   provider,
		publisher:  publisher,
		registry:   registry,
		renderer:   renderer,
		site:       site,
		subscriber: subscriber,
		topic:      topic,
		tracer:     tracer,
	}
}

func (builder *KrillBuilder) Parse(configuration Simulation) error {
	err := builder.broker.Create(BrokerID, &broker.Component{
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

func (builder *KrillBuilder) ParseSite(configuration Site) error {
	err := builder.site.Create(component.ID(configuration.Name), &site.Component{
		Name: configuration.Name,
	})
	if err != nil {
		return err
	}

	tags, err := builder.ParseTags(configuration)
	if err != nil {
		return err
	}

	err = builder.provider.Create(component.ID(configuration.Name), &provider.Component{
		Type: provider.COUNTER,
		Name: fmt.Sprintf(ProviderIDFormat, configuration.Name),
	})
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

func (builder *KrillBuilder) ParseTopics(configuration Site, tags []string, assets []string) error {
	templateExecutor, err := templater.NewExecutor(configuration.TopicFormat)
	if err != nil {
		return err
	}

	topicTemplate := templater.New[TopicTemplate](templateExecutor)

	for _, asset := range assets {
		for _, tag := range tags {
			topicID := fmt.Sprintf(TopicIDFormat, configuration.Name, asset, tag)

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

			err = builder.ParseTopicAndPublisher(configuration, topicID, string(res), asset, tag)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

func (builder *KrillBuilder) ParseTopicAndPublisher(configuration Site, id string, name string, asset string, tag string) error {
	err := builder.topic.Create(component.ID(id), &topic.Component{
		Name: name,
	})
	if err != nil {
		return err
	}

	err = builder.limiter.Create(component.ID(id), &limiter.Component{
		Limit:         configuration.Rate.MessagesPerPeriod,
		PeriodSeconds: configuration.Rate.PeriodSeconds,
	})
	if err != nil {
		return err
	}

	return builder.publisher.Create(component.ID(id), &publisher.Component{
		TopicID:           component.ID(id),
		ClientID:          component.ID(asset),
		RendererID:        component.ID(tag),
		QoSLevel:          configuration.QoSLevel,
		LimiterID:         component.ID(id),
		RendersPerPublish: configuration.Rate.TagsPerMessage,
	})
}

func (builder *KrillBuilder) ParseTags(configuration Site) ([]string, error) {
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

func (builder *KrillBuilder) ParseAssets(configuration Site) ([]string, error) {
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

func (builder *KrillBuilder) ParseAsset(configuration Site, count int) (string, error) {
	clientID := fmt.Sprintf(ClientIDFormat, configuration.Name, count)

	err := builder.registry.Create(component.ID(clientID), &registry.Component{})
	if err != nil {
		return "", err
	}

	err = builder.observer.Create(component.ID(clientID), &observer.Component{
		RegistryID: component.ID(clientID),
		ProviderID: component.ID(configuration.Name),
		Label:      clientID,
	})
	if err != nil {
		return "", err
	}

	err = builder.client.Create(component.ID(clientID), &client.Component{
		SiteID:     component.ID(configuration.Name),
		BrokerID:   BrokerID,
		Name:       clientID,
		Type:       client.Type(configuration.MQTTVersion),
		RegistryID: component.ID(clientID),
	})
	if err != nil {
		return "", err
	}

	return clientID, nil
}

func (builder *KrillBuilder) ParseJSONTagPerMessage(configuration Site) ([]string, error) {
	err := builder.formatter.Create(component.ID(configuration.Name), &formatter.Component{
		Type: formatter.JSON,
	})
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

func (builder *KrillBuilder) ParseJSONTag(siteName string, tag Tag, count int) (string, error) {
	tagID := fmt.Sprintf(TagIDFormat, siteName, tag.ID, count)
	childID := fmt.Sprintf(TagChildIDFormat, tagID)

	err := builder.ParseRootNode(siteName, tagID, node.COLLECTION)
	if err != nil {
		return "", err
	}

	err = builder.ParseExpressionNode(tagID, childID, tagID, tag.Configuration, tagID, edge.LABEL)
	if err != nil {
		return "", err
	}

	return tagID, nil
}

func (builder *KrillBuilder) ParseOPCUA(configuration Site) ([]string, error) {
	err := builder.ParseFormatter(configuration.Name, formatter.JSON, node.COLLECTION)
	if err != nil {
		return nil, err
	}

	timestampID := fmt.Sprintf(TagTimestampIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(configuration.Name, timestampID, timestampID, OPCUATimeExpression, OPCUATimeConfiguration, edge.LABEL)
	if err != nil {
		return nil, err
	}

	sequenceID := fmt.Sprintf(TagSequenceIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(configuration.Name, sequenceID, sequenceID, OPCUASequenceExpression, OPCUASequenceConfiguration, edge.LABEL)
	if err != nil {
		return nil, err
	}

	datasetWriterID := fmt.Sprintf(TagDatasetWriterIDFormat, configuration.Name)

	err = builder.ParseExpressionNode(configuration.Name, datasetWriterID, datasetWriterID, OPCUADatasetWriterExpression, OPCUADatasetWriterConfiguration, edge.LABEL)
	if err != nil {
		return nil, err
	}

	payloadID := fmt.Sprintf(TagPayloadIDFormat, configuration.Name)

	err = builder.ParseCollectionNode(configuration.Name, payloadID, payloadID, OPCUAPayloadConfiguration)
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

func (builder *KrillBuilder) ParseOPCUATag(configuration Site, rootId string, tag Tag, count int) error {
	tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

	err := builder.ParseCollectionNode(rootId, tagID, tagID, tagID)
	if err != nil {
		return err
	}

	valueID := fmt.Sprintf(TagValueIDFormat, tagID)

	err = builder.ParseExpressionNode(tagID, valueID, valueID, tag.Configuration, OPCUAValueConfiguration, edge.LABEL)
	if err != nil {
		return err
	}

	sourceTimestampID := fmt.Sprintf(TagSourceTimestampIDFormat, tagID)

	return builder.ParseExpressionNode(tagID, sourceTimestampID, sourceTimestampID, OPCUASourceTimeExpression, OPCUASourceTimestampConfiguration, edge.LABEL)
}

func (builder *KrillBuilder) ParseExpressionNode(rootNodeId, nodeId, edgeId, nodeExpression string, edgeConfiguration any, edgeType edge.Type) error {
	err := builder.node.Create(component.ID(nodeId), &node.Component{
		Type:          node.EXPRESSION,
		Configuration: nodeExpression,
	})
	if err != nil {
		return err
	}

	return builder.edge.Create(component.ID(edgeId), &edge.Component{
		ParentNodeId:  component.ID(rootNodeId),
		ChildNodeId:   component.ID(nodeId),
		Type:          edgeType,
		Configuration: edgeConfiguration,
	})
}

func (builder *KrillBuilder) ParseCollectionNode(rootNodeId, nodeId, edgeId, edgeConfiguration string) error {
	err := builder.node.Create(component.ID(nodeId), &node.Component{
		Type: node.COLLECTION,
	})
	if err != nil {
		return err
	}

	return builder.edge.Create(component.ID(edgeId), &edge.Component{
		ParentNodeId:  component.ID(rootNodeId),
		ChildNodeId:   component.ID(nodeId),
		Type:          edge.LABEL,
		Configuration: edgeConfiguration,
	})
}

func (builder *KrillBuilder) ParseComplex(configuration Site, format formatter.Type) ([]string, error) {
	err := builder.ParseFormatter(configuration.Name, format, node.COLLECTION)
	if err != nil {
		return nil, err
	}

	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

			err := builder.ParseExpressionNode(configuration.Name, tagID, tagID, tag.Configuration, tagID, edge.LABEL)
			if err != nil {
				return nil, err
			}
		}
	}

	return []string{configuration.Name}, nil
}

func (builder *KrillBuilder) ParseFormatter(id string, format formatter.Type, nodeType node.Type) error {
	err := builder.formatter.Create(component.ID(id), &formatter.Component{
		Type: format,
	})
	if err != nil {
		return err
	}

	return builder.ParseRootNode(id, id, nodeType)
}

func (builder *KrillBuilder) ParseRootNode(formatterID string, id string, nodeType node.Type) error {
	err := builder.node.Create(component.ID(id), &node.Component{
		Type: nodeType,
	})
	if err != nil {
		return err
	}

	return builder.renderer.Create(component.ID(id), &renderer.Component{
		FormatterID: component.ID(formatterID),
		NodeID:      component.ID(id),
	})
}

func (builder *KrillBuilder) ParseFlat(configuration Site, format formatter.Type) ([]string, error) {

	err := builder.ParseFormatter(configuration.Name, format, node.ARRAY)
	if err != nil {
		return nil, err
	}

	field := 0
	for _, tag := range configuration.Tags {
		for count := 0; count < tag.Count; count++ {
			tagID := fmt.Sprintf(TagIDFormat, configuration.Name, tag.ID, count)

			err := builder.ParseExpressionNode(configuration.Name, tagID, tagID, tag.Configuration, field, edge.POSITION)
			if err != nil {
				return nil, err
			}

			field++
		}
	}

	return []string{configuration.Name}, nil
}
