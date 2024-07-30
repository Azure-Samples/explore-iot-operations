// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strconv"

	dapr "github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/http"
)

type OrderDetails struct {
	Number uint   `json:"orderId"`
	Name   string `json:"item"`
}

const (
	stateStoreComponentName = "iotoperations-statestore"
	pubSubComponentName     = "iotoperations-pubsub"
	daprServerPort          = ":6001"
)

var ordersSubscription = &common.Subscription{
	PubsubName: pubSubComponentName,
	Topic:      "orders",
	Route:      "/some-orders",
}

var oddOrdersSubscription = &common.Subscription{
	PubsubName: pubSubComponentName,
	Topic:      "odd-numbered-orders",
	Route:      "/odd-numbered-orders",
}

func main() {
	// create a Dapr service for subscribing
	server := daprd.NewService(daprServerPort)

	// create a Dapr client for publishing
	client, err := dapr.NewClient()
	if err != nil {
		panic(err)
	}

	if err := server.AddTopicEventHandler(ordersSubscription, ordersEventHandler(client)); err != nil {
		log.Fatalf("error adding topic subscription: %v", err)
	}

	if err := server.AddTopicEventHandler(oddOrdersSubscription, oddOrdersEventHandler(client)); err != nil {
		log.Fatalf("error adding topic subscription: %v", err)
	}

	if err := server.Start(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("error listening: %v", err)
	}
}

func ordersEventHandler(client dapr.Client) common.TopicEventHandler {
	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		log.Printf("orders event - PubsubName: %s, Topic: %s, ID: %s, Data: %s", e.PubsubName, e.Topic, e.ID, e.Data)

		var order OrderDetails
		s, _ := strconv.Unquote(string(e.RawData))
		err = json.Unmarshal([]byte(s), &order)
		if err != nil {
			log.Printf("Could not decode data: %v", err)
			return false, err
		}
		log.Printf("Order number is %d with name %s", order.Number, order.Name)

		// If the order Id is an odd number, republish on a new topic
		if order.Number%2 != 0 {

			// PubsubName seems to be in e.Topic when published by a pure MQTT client
			if err := client.PublishEvent(ctx, e.Topic, "odd-numbered-orders", e.Data); err != nil {
				panic(err)
			}
			log.Printf("Published to odd-numbered-orders: %v", e)
		}

		return false, nil
	}
}

func oddOrdersEventHandler(client dapr.Client) common.TopicEventHandler {
	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		log.Printf("addOrders event - PubsubName: %s, Topic: %s, ID: %s, Data: %s", e.PubsubName, e.Topic, e.ID, e.Data)

		var order OrderDetails
		err = json.Unmarshal([]byte(e.RawData), &order)
		if err != nil {
			log.Printf("Could not decode data: %v", err)
			return false, err
		}
		log.Printf("Odd order number is %d with name %s", order.Number, order.Name)

		// save to the state store
		if err := client.SaveState(ctx, stateStoreComponentName, strconv.FormatUint(uint64(order.Number), 10), []byte(order.Name), nil); err != nil {
			log.Printf("Error saving state: %v", err)
			return true, err
		}

		log.Printf("Saved order #%d", order.Number)

		// get from the state store
		state, err := client.GetState(ctx, stateStoreComponentName, strconv.FormatUint(uint64(order.Number), 10), nil);
		if err != nil {
			log.Printf("Error getting state: %v", err)
			return true, err
		}

		log.Printf("Got order #%d, state %s", order.Number, state.Value)

		return false, nil
	}
}

func runHandler(ctx context.Context, in *common.BindingEvent) (out []byte, err error) {
	log.Printf("binding - Data:%s, Meta:%v", in.Data, in.Metadata)
	return nil, nil
}