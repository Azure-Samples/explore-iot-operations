// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"log"
	"net/http"

	"github.com/dapr/go-sdk/service/common"
	dapr "github.com/dapr/go-sdk/client"
	daprd "github.com/dapr/go-sdk/service/http"
)

var PUBSUB_NAME = "aio-mq-pubsub" 
var SERVICE_BUS_NAME = "servicebus-binding"

var (
	c   dapr.Client
	err error
	ctx context.Context
)

var messageSub = &common.Subscription{
	PubsubName: PUBSUB_NAME,
	Topic:      "servicebus",
	Route:      "/servicebus",
	Metadata:   map[string]string {"rawPayload": "true"},
}

func init() {
}

func main() {
	c, err := dapr.NewClient()
	if err != nil {
		panic(err)
	}

	// create a Dapr service
	s := daprd.NewService(":6001")

	if err := s.AddTopicEventHandler(messageSub, eventHandler(c)); err != nil {

		log.Fatalf("error adding topic subscription: %v", err)
	}

	if err := s.Start(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("error listening: %v", err)
	}
}

func eventHandler(c dapr.Client) common.TopicEventHandler {
	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		log.Printf("event: Topic:%s, ID:%s, Data:%s", e.PubsubName, e.Topic, e.ID, e.Data)

		// Send to service bus
		BINDING_OPERATION := "create"
		in := &dapr.InvokeBindingRequest{Name: SERVICE_BUS_NAME, Operation: BINDING_OPERATION, Data: []byte(e.RawData)}
		if err := c.InvokeOutputBinding(ctx, in); err != nil {
			panic(err)
		}
		log.Println("event: Send message to service bus")

		return false, nil
	}
}

func runHandler(ctx context.Context, in *common.BindingEvent) (out []byte, err error) {
	log.Printf("binding - Data:%s, Meta:%v", in.Data, in.Metadata)
	return nil, nil
}
