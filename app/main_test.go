package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func request(a *app, method, path string) *httptest.ResponseRecorder {
	result := httptest.NewRecorder()
	a.ServeHTTP(result, httptest.NewRequest(method, path, nil))
	return result
}

func TestRoutes(t *testing.T) {
	a := &app{}
	for _, route := range []struct {
		method string
		path   string
		status int
	}{
		{http.MethodGet, "/healthz", http.StatusOK},
		{http.MethodGet, "/readyz", http.StatusOK},
		{http.MethodGet, "/work", http.StatusOK},
		{http.MethodGet, "/metrics", http.StatusOK},
		{http.MethodPost, "/work", http.StatusMethodNotAllowed},
		{http.MethodGet, "/unknown", http.StatusNotFound},
		{http.MethodPost, "/chaos/crash", http.StatusNotFound},
		{http.MethodPost, "/chaos/leak", http.StatusNotFound},
		{http.MethodPost, "/chaos/latency", http.StatusNotFound},
		{http.MethodPost, "/chaos/reset", http.StatusNotFound},
	} {
		if got := request(a, route.method, route.path).Code; got != route.status {
			t.Errorf("%s %s status = %d, want %d", route.method, route.path, got, route.status)
		}
	}
	body := request(a, http.MethodGet, "/metrics").Body.String()
	for _, metric := range []string{
		`http_requests_total{path="/work",status="200"} 1`,
		`http_request_duration_seconds_bucket{path="/work",status="200",le="+Inf"} 1`,
		`app_memory_bytes `,
		`app_chaos_active{mode="latency"} 0`,
	} {
		if !strings.Contains(body, metric) {
			t.Errorf("metric not found: %s", metric)
		}
	}
}

func TestChaos(t *testing.T) {
	crashed := false
	a := &app{chaosEnabled: true, crash: func() { crashed = true }}
	t.Cleanup(a.reset)

	if result := request(a, http.MethodPost, "/chaos/crash"); result.Code != http.StatusAccepted || !crashed {
		t.Fatal("crash endpoint did not invoke crash")
	}
	if got := request(a, http.MethodPost, "/chaos/latency?ms=-1").Code; got != http.StatusBadRequest {
		t.Fatalf("invalid latency status = %d", got)
	}
	if got := request(a, http.MethodPost, "/chaos/latency?ms=10000").Code; got != http.StatusAccepted {
		t.Fatalf("latency status = %d", got)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	a.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/work", nil).WithContext(ctx))
	body := request(a, http.MethodGet, "/metrics").Body.String()
	if !strings.Contains(body, `http_requests_total{path="/work",status="408"} 1`) {
		t.Fatal("delayed work did not stop on request cancellation")
	}
	if got := request(a, http.MethodPost, "/chaos/leak").Code; got != http.StatusAccepted {
		t.Fatalf("leak status = %d", got)
	}
	deadline := time.Now().Add(time.Second)
	for {
		a.mu.Lock()
		allocated := len(a.allocations)
		a.mu.Unlock()
		if allocated > 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("leak did not allocate memory")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := request(a, http.MethodPost, "/chaos/reset").Code; got != http.StatusNoContent {
		t.Fatalf("reset status = %d", got)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.latency != 0 || a.leakStop != nil || len(a.allocations) != 0 {
		t.Fatal("reset did not clear fault state")
	}
}

func TestWriteHeapProfile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "heap.pprof")
	if err := writeHeapProfile(path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) < 2 || data[0] != 0x1f || data[1] != 0x8b {
		t.Fatal("heap profile is not gzip")
	}
}
