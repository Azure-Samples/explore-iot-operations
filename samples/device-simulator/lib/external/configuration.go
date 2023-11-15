// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package external

type (
	// Tag describes the structure of a simulated tag, including its ID,
	// count (of how many instances of the tag to create), configuration (the equation which describes the behavior of this tag),
	// and the missingChance (the percent chance that the tag will not be rendered).
	Tag struct {
		ID            string `json:"id" yaml:"id"`
		Configuration string `json:"configuration" yaml:"configuration"`
		Count         int    `json:"count" yaml:"count"`
		MissingChance int    `json:"missingChance" yaml:"missingChance"`
	}

	// Rate describes the flow of message publishes from the simulator,
	// where limit describes the maximum number of services which leave the simulator over a period of PeriodSeconds.
	// TagsPerMessage describes how many tags should be rendered per message sent.
	Rate struct {
		MessagesPerPeriod int `json:"messagesPerPeriod" yaml:"messagesPerPeriod"`
		PeriodSeconds     int `json:"periodSeconds" yaml:"periodSeconds"`
		TagsPerMessage    int `json:"tagsPerMessage" yaml:"tagsPerMessage"`
	}

	// Site describes a logical collection of simulated devices.
	Site struct {
		// Name is the name of a site which will be used in creating topics for assets in this site.
		Name string `json:"name" yaml:"name"`

		// Tags is a collection of tags which each asset in this site will send.
		Tags []Tag `json:"tags" yaml:"tags"`

		// AssetCount is the number of total assets in this site, each represented by their own MQTT connection to the broker.
		AssetCount int `json:"assetCount" yaml:"assetCount"`

		// Rate describes the flow of messages for each asset.
		Rate Rate `json:"rate" yaml:"rate"`

		// PayloadFormat describes the shape of data sent by each asset (JSON, binary, CSV, etc.).
		PayloadFormat string `json:"payloadFormat" yaml:"payloadFormat"`

		// TopicFormat describes the format of the template that each asset will publish messages on.
		TopicFormat string `json:"topicFormat" yaml:"topicFormat"`

		// QoSLevel describes the QoS level of all message publishes by all assets.
		QoSLevel int `json:"qosLevel" yaml:"qosLevel"`

		// MQTTVersion describes the MQTT protocol version to use for this site (v3 or v5).
		MQTTVersion string `json:"mqttVersion" yaml:"mqttVersion"`
	}

	// Target describes the target MQTT broker host and port.
	Target struct {
		Host string `json:"host" yaml:"host"`
		Port int    `json:"port" yaml:"port"`
	}

	// Simulation describes the overall configuration for a simulation, including
	// a collection of sites, a collection of refDatas, and an MQTT target.
	Simulation struct {
		Sites  []Site `json:"sites" yaml:"sites"`
		Target Target `json:"target" yaml:"target"`
	}

	// Ports describes the ports of prometheus metrics data and the ref data application server.
	Ports struct {
		Metrics int `json:"metrics" yaml:"metrics"`
		RefData int `json:"refData" yaml:"refData"`
	}

	// Configuration describes the overall configuration structure for the simulator.
	Configuration struct {
		Simulation Simulation `json:"simulation" yaml:"simulation"`
		Ports      Ports      `json:"ports" yaml:"ports"`
		LogLevel   int        `json:"logLevel" yaml:"logLevel"`
	}

	TopicTemplate struct {
		SiteName  string
		AssetName string
		TagName   string
	}
)

const (
	BrokerID          = "0"
	ClientIDFormat    = "%s__asset_%d"
	TopicIDFormat     = "%s__%s__%s"
	TagIDFormat       = "%s__%s__%d"
	TagParentIDFormat = "%s__parent"
	TagChildIDFormat  = "%s__child"
	ProviderIDFormat  = "device_simulator_%s_asset_publish_counter"

	TagTimestampIDFormat   = "%s__timestamp"
	OPCUATimeExpression    = "now()"
	OPCUATimeConfiguration = "Timestamp"

	TagSequenceIDFormat        = "%s__sequence"
	OPCUASequenceExpression    = "x"
	OPCUASequenceConfiguration = "SequenceNumber"

	TagDatasetWriterIDFormat        = "%s__dataset_writer"
	OPCUADatasetWriterExpression    = `concat(site, concat("_", id))`
	OPCUADatasetWriterConfiguration = "DataSetWriterName"

	TagPayloadIDFormat        = "%s__payload"
	OPCUAPayloadConfiguration = "Payload"

	TagValueIDFormat        = "%s__value"
	OPCUAValueConfiguration = "Value"

	TagSourceTimestampIDFormat        = "%s__source_timestamp"
	OPCUASourceTimeExpression         = OPCUATimeExpression
	OPCUASourceTimestampConfiguration = "SourceTimestamp"
)

const (
	Logo = `
 ____          _            _____ _           _     _           
|    \ ___ _ _|_|___ ___   |   __|_|_____ _ _| |___| |_ ___ ___ 
|  |  | -_| | | |  _| -_|  |__   | |     | | | | .'|  _| . |  _|
|____/|___|\_/|_|___|___|  |_____|_|_|_|_|___|_|__,|_| |___|_|    
`
)
