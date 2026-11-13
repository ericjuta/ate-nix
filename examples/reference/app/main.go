// Command reference-app is the smallest service that is worth deploying: it
// answers every request with a JSON document.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type reply struct {
	Service string `json:"service"`
	Path    string `json:"path"`
}

func handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(reply{Service: "reference-app", Path: r.URL.Path})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Fatal(http.ListenAndServe(":"+port, http.HandlerFunc(handler)))
}
