package publishWorkflow

import (
	"fmt"
	"log"

	dapr "github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/workflow"
)

type Target struct {
	Client    dapr.Client
	Component string
	Topic     string
}

var target Target

func RegisterWorkflow(w *workflow.WorkflowWorker, _target Target) {
	target = _target

	// Register the activities
	if err := w.RegisterActivity(FahrenheitToCelciusActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	if err := w.RegisterActivity(printToConsoleActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	if err := w.RegisterActivity(publishToTopicActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	fmt.Println("Activities registered")

	// Register the workflow
	if err := w.RegisterWorkflow(PublishWorkflow); err != nil {
		log.Fatal("Failed to register workflow: ", err)
	}
	fmt.Println("TestWorkflow registered")
}

func PublishWorkflow(ctx *workflow.WorkflowContext) (any, error) {
	var sensor Sensor
	if err := ctx.GetInput(&sensor); err != nil {
		fmt.Println("Failed to get payload input")
		return sensor, err
	}

	var enrichedSensor Sensor
	if err := ctx.CallActivity(FahrenheitToCelciusActivity, workflow.ActivityInput(sensor)).Await(&enrichedSensor); err != nil {
		fmt.Println("FahrenheitToCelciusActivity failed ", err)
		return 0, err
	}

	if err := ctx.CallActivity(printToConsoleActivity, workflow.ActivityInput(enrichedSensor)).Await(nil); err != nil {
		fmt.Println("consoleActivity failed ", err)
		return 0, err
	}

	if err := ctx.CallActivity(publishToTopicActivity, workflow.ActivityInput(enrichedSensor)).Await(nil); err != nil {
		fmt.Println("consoleActivity failed ", err)
		return 0, err
	}

	return enrichedSensor, nil
}

func FahrenheitToCelciusActivity(ctx workflow.ActivityContext) (any, error) {
	var input Sensor
	if err := ctx.GetInput(&input); err != nil {
		return input, err
	}

	input.TemperatureC = (input.TemperatureF - 32) * 5 / 9
	return input, nil
}

func printToConsoleActivity(ctx workflow.ActivityContext) (any, error) {
	var payload Sensor
	if err := ctx.GetInput(&payload); err != nil {
		return payload, err
	}

	fmt.Printf("printToConsoleActivity: %+v\n", payload)
	return payload, nil
}

func publishToTopicActivity(ctx workflow.ActivityContext) (any, error) {
	var payload Sensor
	if err := ctx.GetInput(&payload); err != nil {
		return payload, err
	}

	fmt.Printf("publishToTopicActivity: topic:%s, payload:%+v\n", target.Topic, payload)

	if err := target.Client.PublishEvent(ctx.Context(), target.Component, target.Topic, payload); err != nil {
		fmt.Println("Failed to publish")
		return payload, err
	}

	return nil, nil
}
