package serving

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/reddydMSFT/callout/pkg/models"
)

// compute qfactor
func qFactor(w http.ResponseWriter, r *http.Request) {
	req, err := io.ReadAll(r.Body)
	if handleError(err, w) {
		return
	}

	var quality models.Quality
	err = json.Unmarshal(req, &quality)
	if handleError(err, w) {
		return
	}

	// compute qfactor
	var compound = quality.Payload.Temperature * quality.Payload.Humidity
	if quality.Payload.Age < 1 {
		quality.Payload.QFactor = 1.0
	} else if compound > 7200 && compound <= 8000 {
		quality.Payload.QFactor = 0.2
	} else if compound > 8000 && compound <= 9740 {
		quality.Payload.QFactor = 0.8
	} else if compound > 9740 && compound <= 11000 {
		quality.Payload.QFactor = 0.5
	} else {
		quality.Payload.QFactor = 0.0
	}

	// set Quality name
	if quality.Payload.QFactor >= 0.6 {
		quality.Payload.Quality = "Good"
	} else if quality.Payload.QFactor >= 0.3 && quality.Payload.QFactor < 0.6 {
		quality.Payload.Quality = "Inspect"
	} else {
		quality.Payload.Quality = "Bad"
	}

	// set Shift info
	//aformat := time.RFC3339
	format := "2006-01-02T15:04:05.999Z"
	ts, err := time.Parse(format, quality.Payload.SourceTimestamp)
	if handleError(err, w) {
		return
	}
	quality.Payload.Shift = (ts.Hour() / 8) + 1

	w.Header().Set("Content-Type", "application/json")
	err = json.NewEncoder(w).Encode(quality)
	handleError(err, w)
}
