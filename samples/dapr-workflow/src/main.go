// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"daprworkflow/publishWorkflow"

	dapr "github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/grpc"
	"github.com/dapr/go-sdk/workflow"
)

var messageSub = &common.Subscription{
	PubsubName: pubSubName,
	Topic:      "sensor/in",
	Route:      "/sensorin",
	Metadata:   map[string]string{"rawPayload": "true"},
}

const (
	appPort    = ":6001"
	pubSubName = "aio-mq-pubsub"
)

func main() {
	fmt.Println("Starting app")

	// Create the wf worker
	w, err := workflow.NewWorker()
	if err != nil {
		log.Fatal("Failed to create workflow worker: ", err)
	}
	defer w.Shutdown()
	fmt.Println("Worker initialized")

	// Start wf runner
	if err := w.Start(); err != nil {
		log.Fatal("Failed to start workflow runner: ", err)
	}
	fmt.Println("Runner started")

	daprClient, err := dapr.NewClient()
	if err != nil {
		log.Fatalf("Failed to initialise dapr client: %v", err)
	}

	// Register my test workflow
	target := publishWorkflow.Target{
		Client:    daprClient,
		Component: pubSubName,
		Topic:     "sensor/out",
	}
	publishWorkflow.RegisterWorkflow(w, target)

	// Create a Dapr service
	daprService, err := daprd.NewService(appPort)
	if err != nil {
		log.Fatal("Failed to Dapr service: ", err)
	}
	fmt.Println("Dapr service created")

	// Subscribe to topic
	if err := daprService.AddTopicEventHandler(messageSub, subscribeHandler); err != nil {

		log.Fatal("Failed to add topic subscription: ", err)
	}
	fmt.Println("Subscribed to topic")

	// Start service, blocks here
	if err := daprService.Start(); err != nil && err != http.ErrServerClosed {
		log.Fatal("error starting Dapr service: ", err)
	}

	fmt.Println("End")
}

func subscribeHandler(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
	var sensor publishWorkflow.Sensor
	if err := json.Unmarshal(e.RawData, &sensor); err != nil {
		fmt.Println("Invalid sensor data")
		return false, nil
	}

	wfClient, err := workflow.NewClient()
	if err != nil {
		log.Fatalf("Failed to initialise workflow client: %v", err)
	}

	id, err := wfClient.ScheduleNewWorkflow(ctx, "PublishWorkflow", workflow.WithInput(sensor))
	if err != nil {
		log.Fatalf("Failed to schedule new workflow: %v", err)
	}
	fmt.Println("Workflow started with id:", id)

	return false, nil
}
