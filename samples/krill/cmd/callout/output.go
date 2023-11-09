package main

import (
	"context"
	"fmt"
	"net"
	"strings"

	mqttv5 "github.com/eclipse/paho.golang/paho"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

type InvalidOutputNameError struct {
	name string
}

func (err *InvalidOutputNameError) Error() string {
	return fmt.Sprintf("the output with the name %q could not be found", err.name)
}

type InvalidOutputTypeError struct {
	output string
}

func (err *InvalidOutputTypeError) Error() string {
	return fmt.Sprintf("%q is not a valid output type", err.output)
}

type Out interface {
	Out(content []byte) error
}

type OutputCollection struct {
	m       map[string]Out
	outputs []Output
	Logger  logger.Logger
}

func NewOutputCollection(outputs []Output, options ...func(*OutputCollection)) *OutputCollection {
	collection := &OutputCollection{
		m:       make(map[string]Out),
		outputs: outputs,
	}

	for _, option := range options {
		option(collection)
	}

	return collection
}

func (collection *OutputCollection) Get(name string) (Out, error) {
	res, ok := collection.m[name]
	if !ok {
		return nil, &InvalidOutputNameError{
			name: name,
		}
	}

	return res, nil
}

func (collection *OutputCollection) Setup() error {
	for _, output := range collection.outputs {
		err := collection.Output(output)
		if err != nil {
			return err
		}
	}

	return nil
}

func (collection *OutputCollection) Output(output Output) error {
	switch strings.ToLower(output.Type) {
	case "mqtt":
		o, err := NewMQTTOutput(output)
		if err != nil {
			return err
		}
		collection.m[output.Name] = o
	case "stdout":
		collection.m[output.Name] = NewStdoutOutput(func(so *StdoutOutput) {
			so.Logger = collection.Logger
		})
	default:
		return &InvalidOutputTypeError{
			output: output.Type,
		}
	}

	return nil
}

type MQTTOutput struct {
	cli   *mqttv5.Client
	topic string
	qos   int
}

func NewMQTTOutput(output Output) (*MQTTOutput, error) {
	conn, err := net.Dial("tcp", output.Endpoint)
	if err != nil {
		return nil, err
	}

	cli := mqttv5.NewClient(mqttv5.ClientConfig{
		Router:   mqttv5.NewStandardRouter(),
		Conn:     conn,
		ClientID: output.Name,
	})
	cli.ClientID = output.Name

	cp := &mqttv5.Connect{
		KeepAlive:  5,
		CleanStart: true,
		ClientID:   output.Name,
	}
	_, err = cli.Connect(context.Background(), cp)
	if err != nil {
		return nil, err
	}

	return &MQTTOutput{
		cli:   cli,
		topic: output.Path,
		qos:   output.QoS,
	}, nil
}

func (output *MQTTOutput) Out(content []byte) error {
	_, err := output.cli.Publish(context.Background(), &mqttv5.Publish{
		QoS:     byte(output.qos),
		Topic:   output.topic,
		Payload: content,
	})
	return err
}

type StdoutOutput struct {
	Logger logger.Logger
}

func NewStdoutOutput(options ...func(*StdoutOutput)) *StdoutOutput {
	out := &StdoutOutput{
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(out)
	}

	return out
}

func (output *StdoutOutput) Out(content []byte) error {
	output.Logger.Level(logger.Debug).With("content", string(content)).Printf("server received new content")
	return nil
}
