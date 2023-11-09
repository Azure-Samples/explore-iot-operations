package serving

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"

	"github.com/gorilla/mux"
	"github.com/rs/zerolog/log"
)

// echo the contents of the body back to response and print to STDOUT
func echoRequest(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	paramStr := ""
	for key, value := range vars {
		paramStr += key + "=" + value + " "
	}

	req, err := io.ReadAll(r.Body)
	if handleError(err, w) {
		return
	}

	// print pretty json
	var prettyJSON bytes.Buffer
	err = json.Indent(&prettyJSON, req, "", "  ")
	if handleError(err, w) {
		return
	}

	log.Debug().Msgf("Request: %s\n%s", paramStr, prettyJSON.String())

	w.Header().Set("Content-Type", "application/json")
	_, err = w.Write(req)
	handleError(err, w)
}
