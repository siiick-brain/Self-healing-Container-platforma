package main

import (
	"fmt"
	"net/http"
	"runtime"
	"slices"
	"strconv"
	"sync"
)

var bucketBounds = [...]float64{.005, .01, .025, .05, .1, .2, .3, .5, 1, 2.5, 5, 10}

type metricKey struct {
	path   string
	status int
}

type observation struct {
	count   uint64
	buckets [len(bucketBounds)]uint64
	sum     float64
}

type metrics struct {
	mu     sync.Mutex
	routes map[metricKey]observation
}

func (m *metrics) observe(path string, status int, seconds float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.routes == nil {
		m.routes = make(map[metricKey]observation)
	}
	key := metricKey{path, status}
	value := m.routes[key]
	value.count++
	value.sum += seconds
	for index, bound := range bucketBounds {
		if seconds <= bound {
			value.buckets[index]++
		}
	}
	m.routes[key] = value
}

func (a *app) writeMetrics(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	a.metrics.mu.Lock()
	keys := make([]metricKey, 0, len(a.metrics.routes))
	for key := range a.metrics.routes {
		keys = append(keys, key)
	}
	slices.SortFunc(keys, func(left, right metricKey) int {
		if left.path == right.path {
			return left.status - right.status
		}
		if left.path < right.path {
			return -1
		}
		return 1
	})
	values := make([]observation, len(keys))
	for index, key := range keys {
		values[index] = a.metrics.routes[key]
	}
	a.metrics.mu.Unlock()

	fmt.Fprintln(w, "# TYPE http_requests_total counter")
	for index, key := range keys {
		fmt.Fprintf(w, "http_requests_total{path=%q,status=%q} %d\n", key.path, strconv.Itoa(key.status), values[index].count)
	}
	fmt.Fprintln(w, "# TYPE http_request_duration_seconds histogram")
	for index, key := range keys {
		labels := fmt.Sprintf("path=%q,status=%q", key.path, strconv.Itoa(key.status))
		value := values[index]
		for b, bound := range bucketBounds {
			fmt.Fprintf(w, "http_request_duration_seconds_bucket{%s,le=%q} %d\n", labels, strconv.FormatFloat(bound, 'f', -1, 64), value.buckets[b])
		}
		fmt.Fprintf(w, "http_request_duration_seconds_bucket{%s,le=\"+Inf\"} %d\n", labels, value.count)
		fmt.Fprintf(w, "http_request_duration_seconds_sum{%s} %g\n", labels, value.sum)
		fmt.Fprintf(w, "http_request_duration_seconds_count{%s} %d\n", labels, value.count)
	}

	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	fmt.Fprintln(w, "# TYPE app_memory_bytes gauge")
	fmt.Fprintf(w, "app_memory_bytes %d\n", mem.Alloc)
	a.mu.Lock()
	latencyActive := a.latency > 0
	leakActive := a.leakStop != nil
	a.mu.Unlock()
	fmt.Fprintln(w, "# TYPE app_chaos_active gauge")
	fmt.Fprintf(w, "app_chaos_active{mode=\"latency\"} %d\n", gauge(latencyActive))
	fmt.Fprintf(w, "app_chaos_active{mode=\"leak\"} %d\n", gauge(leakActive))
}

func gauge(active bool) int {
	if active {
		return 1
	}
	return 0
}
