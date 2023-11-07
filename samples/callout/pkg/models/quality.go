package models

type Quality struct {
	Payload struct {
		Age             int     `json:"age"`
		AssetID         string  `json:"asset_id"`
		AssetName       string  `json:"asset_name"`
		Country         string  `json:"country"`
		Humidity        float64 `json:"humidity"`
		ID              string  `json:"id"`
		MachineStatus   int     `json:"machine_status"`
		OperatingTime   int     `json:"operating_time"`
		Pressure        float64 `json:"pressure"`
		Product         string  `json:"product"`
		Site            string  `json:"site"`
		Temperature     float64 `json:"temperature"`
		Vibration       float64 `json:"vibration"`
		QFactor         float64 `json:"q_factor"`
		Quality         string  `json:"quality"`
		Shift           int     `json:"shift"`
		SourceTimestamp string  `json:"source_timestamp"`
	} `json:"Payload"`
	SequenceNumber int    `json:"SequenceNumber"`
	Timestamp      string `json:"Timestamp"`
}
