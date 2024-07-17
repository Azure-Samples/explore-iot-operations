// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"

	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/grpc"
	"github.com/dapr/go-sdk/workflow"
)

var (
//	wfClient *workflow.Client
//	wfId     string

// daprClient client.Client
// err        error
// ctx        context.Context
)

var messageSub = &common.Subscription{
	PubsubName: pubSubName,
	Topic:      "sensor",
	Route:      "/sensor",
	Metadata:   map[string]string{"rawPayload": "true"},
}

//var stage = 0

const (
	appPort        = ":6001"
	pubSubName     = "aio-mq-pubsub"
	stateStoreName = "aio-mq-statestore"
)

func main() {
	fmt.Println("Starting app")

	// daprClient, err := client.NewClient()
	// if err != nil {
	// 	log.Fatal("Failed to create Dapr client: ", err)
	// }
	// defer daprClient.Close()

	w, err := workflow.NewWorker()
	if err != nil {
		log.Fatal("Failed to create worker: ", err)
	}
	defer w.Shutdown()
	fmt.Println("Worker initialized")

	// Register the workflow
	if err := w.RegisterWorkflow(TestWorkflow); err != nil {
		log.Fatal("Failed to register workflow: ", err)
	}
	fmt.Println("TestWorkflow registered")

	// Register the activities
	if err := w.RegisterActivity(FahrenheitToCelciusActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	if err := w.RegisterActivity(consoleActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	fmt.Println("Activities registered")

	// Start workflow runner
	if err := w.Start(); err != nil {
		log.Fatal("Failed to start workflow runner: ", err)
	}
	fmt.Println("Runner started")

	// Create workflow client
	// wfClient, err = workflow.NewClient()
	// if err != nil {
	// 	log.Fatal("Failed to create workflow client: ", err)
	// }
	// fmt.Println("Workflow client created")

	//	fmt.Printf("stage: %d\n", stage)

	// ctx := context.Background()
	// id, err := wfClient.ScheduleNewWorkflow(ctx, "TestWorkflow", workflow.WithInput(1))
	// if err != nil {
	// 	log.Fatal("Failed to schedule a new workflow: ", err)
	// }
	// fmt.Println("Workflow started with id: ", id)

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

	// Start service
	if err := daprService.Start(); err != nil && err != http.ErrServerClosed {
		log.Fatal("error starting Dapr service: ", err)
	}

	fmt.Println("Complete")
	//	fmt.Printf("stage: %d\n", stage)

	// if err := wfClient.RaiseEvent(ctx, id, "testEvent"); err != nil {
	// 	log.Fatal("Failed to raise event: ", err)
	// }
	// fmt.Println("Event raised")

	///	fmt.Printf("stage: %d\n", stage)

	// metadata, err := wfClient.WaitForWorkflowCompletion(ctx, id)
	// if err != nil {
	// 	log.Fatal("Failed to wait for workflow: ", err)
	// }
	// fmt.Println("Workflow complete status:", metadata.RuntimeStatus.String())

	// fmt.Printf("stage: %d\n", stage)
}

func subscribeHandler(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
	fmt.Printf("event: Topic:%s, ID:%s, Data:%s\n", e.Topic, e.ID, e.RawData)

	var sensor SensorPayload
	if err := json.Unmarshal(e.RawData, &sensor); err != nil {
		fmt.Println("Invalid sensor data")
		return false, nil
	}

	wfClient, err := workflow.NewClient()
	if err != nil {
		log.Fatalf("Failed to initialise workflow client: %v", err)
	}

	id, err := wfClient.ScheduleNewWorkflow(ctx, "TestWorkflow", workflow.WithInput(sensor))
	if err != nil {
		log.Fatalf("Failed to schedule new workflow: %v", err)
	}
	fmt.Println("Workflow started with id: ", id)

	metadata, err := wfClient.WaitForWorkflowCompletion(ctx, id)
	if err != nil {
		log.Fatal("Failed to wait for workflow: ", err)
	}

	if metadata.RuntimeStatus != workflow.StatusCompleted {
		return true, errors.New("failed, please retry")
	}

	fmt.Println("output:", metadata.SerializedOutput)

	return false, nil
}

func TestWorkflow(ctx *workflow.WorkflowContext) (any, error) {
	var data SensorPayload
	if err := ctx.GetInput(&data); err != nil {
		fmt.Println("Failed to get workflow input")
		return nil, err
	}

	//	fmt.Println("Workflow input ", data)

	//	var output SensorPayload
	if err := ctx.CallActivity(FahrenheitToCelciusActivity, workflow.ActivityInput(data)).Await(&data); err != nil {
		fmt.Println("FahrenheitToCelciusActivity failed ", err)
		return nil, err
	}

	if err := ctx.CallActivity(consoleActivity, workflow.ActivityInput(data)).Await(&data); err != nil {
		fmt.Println("consoleActivity failed ", err)
		return nil, err
	}

	return data, nil
}

func FahrenheitToCelciusActivity(ctx workflow.ActivityContext) (any, error) {
	var input SensorPayload
	if err := ctx.GetInput(&input); err != nil {
		return input, err
	}

	input.TemperatureC = (input.TemperatureF - 32) * 5 / 9
	return input, nil
}

func consoleActivity(ctx workflow.ActivityContext) (any, error) {
	var input SensorPayload
	if err := ctx.GetInput(&input); err != nil {
		return input, err
	}

	fmt.Println("consoleActivity:", input)
	return input, nil
}
