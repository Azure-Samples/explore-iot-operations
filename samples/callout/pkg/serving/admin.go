package serving

import (
	"fmt"
	"net/http"

	"github.com/gorilla/handlers"
	"github.com/gorilla/mux"
	"github.com/rs/zerolog/log"
)

func StartAdmin(port int) {
	router := mux.NewRouter()

	// API routes
	router.HandleFunc("/api/echo/{stage}", echoRequest).Methods(http.MethodGet)
	router.HandleFunc("/api/echo/{stage}", echoRequest).Methods(http.MethodPost)
	router.HandleFunc("/api/qfactor", qFactor).Methods(http.MethodPost)

	log.Info().Msgf("serving callout requests at http://localhost:%d/api", port)
	log.Info().Msgf("you can configure callout stage with Get/POST to http://callout.default.svc.cluster.local/api/echo")

	// handle CORS
	headersOK := handlers.AllowedHeaders([]string{"X-Requested-With", "Content-Type", "Authorization"})
	methodsOK := handlers.AllowedMethods([]string{"GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS"})
	originsOK := handlers.AllowedOrigins([]string{"*"})

	_ = http.ListenAndServe(fmt.Sprintf(":%d", port), handlers.CORS(headersOK, methodsOK, originsOK)(router))
}

// handleError log the error and return http error
func handleError(err error, w http.ResponseWriter) bool {
	if err != nil {
		log.Error().Err(err).Msg("error encountered while processing request")
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return true
	}
	return false
}
