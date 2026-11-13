package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestHandlerReportsThePath(t *testing.T) {
	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("GET", "/orders/7", nil))

	var got reply
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if got.Service != "reference-app" || got.Path != "/orders/7" {
		t.Errorf("reply = %+v, want service reference-app and path /orders/7", got)
	}
}
