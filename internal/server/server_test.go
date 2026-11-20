package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestJobForwardsKeyWithoutPersistingIt(t *testing.T) {
	t.Parallel()
	const secret = "phone-a-test-secret"
	requestDetails := make(chan struct {
		authorization string
		body          map[string]any
	}, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var payload map[string]any
		_ = json.Unmarshal(body, &payload)
		requestDetails <- struct {
			authorization string
			body          map[string]any
		}{r.Header.Get("Authorization"), payload}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{}"}}],"model":"example/model"}`)
	}))
	defer upstream.Close()

	dataDir := t.TempDir()
	application := newTestServer(t, dataDir, upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	job := createJob(t, api.URL, "alice@example.com", secret, "request-a", `{"model":"example/model","stream":true,"stream_options":{"include_usage":true}}`)
	job = waitForTerminalJob(t, api.URL, "alice@example.com", job.ID)
	if job.Status != JobSucceeded {
		t.Fatalf("expected succeeded job, got %#v", job)
	}
	details := <-requestDetails
	if details.authorization != "Bearer "+secret {
		t.Fatalf("unexpected upstream authorization: %q", details.authorization)
	}
	if details.body["stream"] != false {
		t.Fatalf("server must disable streaming for durable jobs: %#v", details.body)
	}
	if _, exists := details.body["stream_options"]; exists {
		t.Fatalf("server must remove stream_options: %#v", details.body)
	}

	files, err := filepath.Glob(filepath.Join(dataDir, "*.json"))
	if err != nil || len(files) != 1 {
		t.Fatalf("expected one persisted job, files=%v err=%v", files, err)
	}
	persisted, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(persisted, []byte(secret)) {
		t.Fatal("persisted job contains the OpenRouter key")
	}
	if bytes.Contains(persisted, []byte("stream_options")) {
		t.Fatal("persisted job contains the request body")
	}
}

func TestIdempotencyReusesRunningAndCompletedJob(t *testing.T) {
	t.Parallel()
	var calls int32
	release := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		<-release
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{}"}}]}`)
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	first := createJob(t, api.URL, "alice@example.com", "first-key", "same-request", `{"model":"example/model"}`)
	second := createJob(t, api.URL, "alice@example.com", "first-key", "same-request", `{"model":"example/model"}`)
	if first.ID != second.ID {
		t.Fatalf("idempotent request created two jobs: %s and %s", first.ID, second.ID)
	}
	close(release)
	finished := waitForTerminalJob(t, api.URL, "alice@example.com", first.ID)
	if finished.Status != JobSucceeded {
		t.Fatalf("expected success, got %#v", finished)
	}
	third := createJob(t, api.URL, "alice@example.com", "first-key", "same-request", `{"model":"example/model"}`)
	if third.ID != first.ID || third.Status != JobSucceeded {
		t.Fatalf("completed idempotent request was not reused: %#v", third)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected one upstream call, got %d", got)
	}
}

func TestServerRejectsExcessConcurrentJobsBeforeReadingAnotherLargeBody(t *testing.T) {
	t.Parallel()
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-release
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{}"}}]}`)
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	application.semaphore = make(chan struct{}, 1)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	first := createJob(t, api.URL, "alice@example.com", "first-key", "first-request", `{"model":"example/model"}`)
	<-started
	request, err := http.NewRequest(
		http.MethodPost,
		api.URL+"/api/v1/jobs",
		strings.NewReader(`{"model":"example/model"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Tailscale-User-Login", "bob@example.com")
	request.Header.Set("Authorization", "Bearer second-key")
	request.Header.Set("Idempotency-Key", "second-request")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable || response.Header.Get("Retry-After") != "1" {
		t.Fatalf("expected retryable capacity response, got %d", response.StatusCode)
	}

	close(release)
	if finished := waitForTerminalJob(t, api.URL, "alice@example.com", first.ID); finished.Status != JobSucceeded {
		t.Fatalf("expected first job to finish, got %#v", finished)
	}
}

func TestTwoTailscaleUsersCanUseDifferentKeys(t *testing.T) {
	t.Parallel()
	keys := make(chan string, 2)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		keys <- r.Header.Get("Authorization")
		_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"{}"}}]}`)
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	first := createJob(t, api.URL, "alice@example.com", "alice-key", "shared-idempotency", `{"model":"example/model"}`)
	second := createJob(t, api.URL, "bob@example.com", "bob-key", "shared-idempotency", `{"model":"example/model"}`)
	if first.ID == second.ID {
		t.Fatal("jobs from different Tailscale users must not be shared")
	}
	_ = waitForTerminalJob(t, api.URL, "alice@example.com", first.ID)
	_ = waitForTerminalJob(t, api.URL, "bob@example.com", second.ID)

	received := map[string]bool{<-keys: true, <-keys: true}
	if !received["Bearer alice-key"] || !received["Bearer bob-key"] {
		t.Fatalf("upstream did not receive both user keys: %#v", received)
	}
}

func TestAPIRequiresTailscaleIdentity(t *testing.T) {
	t.Parallel()
	upstream := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer upstream.Close()
	application := newTestServer(t, t.TempDir(), upstream.URL)
	request := httptest.NewRequest(http.MethodPost, "/api/v1/jobs", strings.NewReader(`{"model":"example/model"}`))
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Idempotency-Key", "request")
	response := httptest.NewRecorder()

	application.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", response.Code, response.Body.String())
	}
}

func TestAllowedMetadataEndpointIsProxiedToFixedUpstream(t *testing.T) {
	t.Parallel()
	requestPath := make(chan string, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestPath <- r.URL.RequestURI()
		if r.Header.Get("Authorization") != "Bearer phone-key" {
			t.Errorf("unexpected authorization header: %q", r.Header.Get("Authorization"))
		}
		_, _ = io.WriteString(w, `{"data":[]}`)
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL+"/api/v1")
	request := httptest.NewRequest(http.MethodGet, "/api/v1/models?sort=most-popular", nil)
	request.Header.Set("Tailscale-User-Login", "alice@example.com")
	request.Header.Set("Authorization", "Bearer phone-key")
	response := httptest.NewRecorder()

	application.Handler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", response.Code, response.Body.String())
	}
	if got := <-requestPath; got != "/api/v1/models?sort=most-popular" {
		t.Fatalf("unexpected upstream path: %s", got)
	}
}

func TestInterruptedJobIsRetriedWithSameIdempotencyKeyAfterRestart(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	firstStore, err := NewJobStore(dataDir, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	created, shouldStart, err := firstStore.CreateOrReuse("owner", "request", "body")
	if err != nil || !shouldStart {
		t.Fatalf("create job: shouldStart=%v err=%v", shouldStart, err)
	}

	reloadedStore, err := NewJobStore(dataDir, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	interrupted, found := reloadedStore.Get(created.ID, "owner")
	if !found || interrupted.Status != JobFailed || !interrupted.Retryable {
		t.Fatalf("interrupted job was not marked retryable: %#v", interrupted)
	}
	restarted, shouldStart, err := reloadedStore.CreateOrReuse("owner", "request", "body")
	if err != nil || !shouldStart {
		t.Fatalf("restart job: shouldStart=%v err=%v", shouldStart, err)
	}
	if restarted.ID != created.ID || restarted.Status != JobRunning || restarted.Attempt != 2 {
		t.Fatalf("unexpected restarted job: %#v", restarted)
	}
}

func TestIdempotencyKeyCannotBeReusedForAnotherRequest(t *testing.T) {
	t.Parallel()
	store, err := NewJobStore(t.TempDir(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateOrReuse("owner", "request", "first-body"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.CreateOrReuse("owner", "request", "other-body"); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("expected idempotency conflict, got %v", err)
	}
}

func newTestServer(t *testing.T, dataDir, upstreamURL string) *Server {
	t.Helper()
	parsed, err := url.Parse(upstreamURL)
	if err != nil {
		t.Fatal(err)
	}
	application, err := New(Config{
		ListenAddr:        ":0",
		DataDir:           dataDir,
		OpenRouterBaseURL: parsed,
		MaxConcurrentJobs: 3,
		MaxRequestBytes:   1024 * 1024,
		MaxResponseBytes:  1024 * 1024,
		JobTTL:            time.Hour,
		UpstreamTimeout:   5 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	return application
}

func createJob(t *testing.T, apiURL, identity, apiKey, idempotencyKey, body string) publicJob {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, apiURL+"/api/v1/jobs", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Tailscale-User-Login", identity)
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Idempotency-Key", idempotencyKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusAccepted && response.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("unexpected create status %d: %s", response.StatusCode, data)
	}
	var job publicJob
	if err := json.NewDecoder(response.Body).Decode(&job); err != nil {
		t.Fatal(err)
	}
	return job
}

func waitForTerminalJob(t *testing.T, apiURL, identity, id string) publicJob {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		request, err := http.NewRequest(http.MethodGet, apiURL+"/api/v1/jobs/"+id, nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Tailscale-User-Login", identity)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		var job publicJob
		err = json.NewDecoder(response.Body).Decode(&job)
		response.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if job.Status != JobRunning {
			return job
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("job did not finish")
	return publicJob{}
}
