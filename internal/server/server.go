package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Server struct {
	config    Config
	store     *JobStore
	client    *http.Client
	semaphore chan struct{}
	jobs      sync.WaitGroup
}

type publicJob struct {
	ID             string    `json:"id"`
	Status         JobStatus `json:"status"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	Attempt        int       `json:"attempt"`
	UpstreamStatus int       `json:"upstream_status,omitempty"`
	ResponseBody   []byte    `json:"response_body,omitempty"`
	FailureCode    string    `json:"failure_code,omitempty"`
	FailureMessage string    `json:"failure_message,omitempty"`
}

func New(config Config) (*Server, error) {
	if config.OpenRouterBaseURL == nil {
		return nil, errors.New("OpenRouter base URL is required")
	}
	store, err := NewJobStore(config.DataDir, config.JobTTL)
	if err != nil {
		return nil, err
	}
	return &Server{
		config:    config,
		store:     store,
		client:    &http.Client{Timeout: config.UpstreamTimeout},
		semaphore: make(chan struct{}, config.MaxConcurrentJobs),
	}, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/api/v1/jobs", s.handleJobs)
	mux.HandleFunc("/api/v1/jobs/", s.handleJob)
	mux.HandleFunc("/api/v1/key", s.handleProxyGET)
	mux.HandleFunc("/api/v1/models", s.handleProxyGET)
	mux.HandleFunc("/api/v1/model/", s.handleProxyGET)
	return securityHeaders(mux)
}

func (s *Server) WaitForJobs(ctx context.Context) bool {
	done := make(chan struct{})
	go func() {
		s.jobs.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-ctx.Done():
		return false
	}
}

func (s *Server) StartCleanup(ctx context.Context) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.store.Cleanup(); err != nil {
				log.Printf("job cleanup failed: %v", err)
			}
		}
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Methode nicht erlaubt.")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, `{"status":"ok"}`)
}

func (s *Server) handleJobs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Methode nicht erlaubt.")
		return
	}
	ownerHash, ok := s.authenticateRequest(w, r)
	if !ok {
		return
	}
	apiKey, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok || len(apiKey) > 4096 {
		writeError(w, http.StatusUnauthorized, "missing_openrouter_key", "OpenRouter-Schlüssel fehlt.")
		return
	}
	idempotencyKey := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if idempotencyKey == "" || len(idempotencyKey) > 160 {
		writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "Idempotency-Key fehlt oder ist zu lang.")
		return
	}
	select {
	case s.semaphore <- struct{}{}:
	default:
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusServiceUnavailable, "server_busy", "Der Server verarbeitet bereits die maximale Anzahl von Aufträgen.")
		return
	}
	slotHandedOff := false
	defer func() {
		if !slotHandedOff {
			<-s.semaphore
		}
	}()

	r.Body = http.MaxBytesReader(w, r.Body, s.config.MaxRequestBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "Anfrage ist zu groß.")
		return
	}
	defer clear(body)
	upstreamBody, err := normalizedChatBody(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_chat_request", err.Error())
		return
	}
	bodyHandedOff := false
	defer func() {
		if !bodyHandedOff {
			clear(upstreamBody)
		}
	}()
	requestHash := hashBytes(body)
	job, shouldStart, err := s.store.CreateOrReuse(ownerHash, idempotencyKey, requestHash)
	if errors.Is(err, ErrIdempotencyConflict) {
		writeError(w, http.StatusConflict, "idempotency_conflict", err.Error())
		return
	}
	if err != nil {
		log.Printf("creating job failed: %v", err)
		writeError(w, http.StatusInternalServerError, "job_storage_failed", "Job konnte nicht gespeichert werden.")
		return
	}
	if shouldStart {
		log.Printf("relay job accepted")
		slotHandedOff = true
		bodyHandedOff = true
		s.jobs.Add(1)
		go s.runJob(job.ID, apiKey, upstreamBody)
	}
	status := http.StatusOK
	if job.Status == JobRunning {
		status = http.StatusAccepted
		w.Header().Set("Retry-After", "1")
	}
	writeJSON(w, status, makePublicJob(job))
}

func (s *Server) handleJob(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Methode nicht erlaubt.")
		return
	}
	ownerHash, ok := s.authenticateRequest(w, r)
	if !ok {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/jobs/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "job_not_found", "Job wurde nicht gefunden.")
		return
	}
	job, found := s.store.Get(id, ownerHash)
	if !found {
		writeError(w, http.StatusNotFound, "job_not_found", "Job wurde nicht gefunden oder ist abgelaufen.")
		return
	}
	if job.Status == JobRunning {
		w.Header().Set("Retry-After", "1")
	}
	writeJSON(w, http.StatusOK, makePublicJob(job))
}

func (s *Server) handleProxyGET(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Methode nicht erlaubt.")
		return
	}
	if _, ok := s.authenticateRequest(w, r); !ok {
		return
	}
	apiKey, ok := bearerToken(r.Header.Get("Authorization"))
	if !ok || len(apiKey) > 4096 {
		writeError(w, http.StatusUnauthorized, "missing_openrouter_key", "OpenRouter-Schlüssel fehlt.")
		return
	}

	relativePath := strings.TrimPrefix(r.URL.Path, "/api/v1")
	upstreamURL := *s.config.OpenRouterBaseURL
	upstreamURL.Path = strings.TrimRight(upstreamURL.Path, "/") + relativePath
	upstreamURL.RawQuery = r.URL.RawQuery
	request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, upstreamURL.String(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "request_failed", "OpenRouter-Anfrage konnte nicht erstellt werden.")
		return
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Accept", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream_transport", "OpenRouter konnte nicht erreicht werden.")
		return
	}
	defer response.Body.Close()
	body, err := readLimited(response.Body, s.config.MaxResponseBytes)
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream_response_too_large", "OpenRouter-Antwort ist zu groß.")
		return
	}
	if contentType := response.Header.Get("Content-Type"); contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	if retryAfter := response.Header.Get("Retry-After"); retryAfter != "" {
		w.Header().Set("Retry-After", retryAfter)
	}
	w.WriteHeader(response.StatusCode)
	_, _ = w.Write(body)
}

func (s *Server) runJob(id, apiKey string, body []byte) {
	defer s.jobs.Done()
	defer clear(body)
	defer func() { <-s.semaphore }()

	ctx, cancel := context.WithTimeout(context.Background(), s.config.UpstreamTimeout)
	defer cancel()
	upstreamURL := *s.config.OpenRouterBaseURL
	upstreamURL.Path = strings.TrimRight(upstreamURL.Path, "/") + "/chat/completions"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, upstreamURL.String(), bytes.NewReader(body))
	if err != nil {
		s.failJob(id, 0, nil, "request_failed", "OpenRouter-Anfrage konnte nicht erstellt werden.", false)
		return
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "Quant-Server/1")
	apiKey = ""

	response, err := s.client.Do(request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			s.failJob(id, 0, nil, "upstream_timeout", "OpenRouter hat nicht rechtzeitig geantwortet.", true)
		} else {
			s.failJob(id, 0, nil, "upstream_transport", "OpenRouter konnte nicht erreicht werden.", true)
		}
		return
	}
	defer response.Body.Close()
	responseBody, err := readLimited(response.Body, s.config.MaxResponseBytes)
	if err != nil {
		s.failJob(id, 0, nil, "upstream_response_too_large", "OpenRouter-Antwort ist zu groß.", false)
		return
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		s.failJob(
			id,
			response.StatusCode,
			responseBody,
			"upstream_http_error",
			"OpenRouter hat die Anfrage abgelehnt.",
			isRetryableStatus(response.StatusCode),
		)
		return
	}
	if !json.Valid(responseBody) {
		s.failJob(id, response.StatusCode, nil, "invalid_upstream_response", "OpenRouter hat ungültiges JSON geliefert.", true)
		return
	}
	if err := s.store.Succeed(id, response.StatusCode, responseBody); err != nil {
		log.Printf("persisting successful job %s failed: %v", id, err)
		return
	}
	log.Printf("relay job completed upstream_status=%d", response.StatusCode)
}

func (s *Server) failJob(id string, status int, body []byte, code, message string, retryable bool) {
	log.Printf("relay job failed code=%s upstream_status=%d retryable=%t", code, status, retryable)
	if err := s.store.Fail(id, status, body, code, message, retryable); err != nil {
		log.Printf("persisting failed job %s failed: %v", id, err)
	}
}

func (s *Server) authenticateRequest(w http.ResponseWriter, r *http.Request) (string, bool) {
	identity := strings.TrimSpace(r.Header.Get("Tailscale-User-Login"))
	if identity == "" && s.config.AllowUnauthenticated && isLoopbackRequest(r) {
		identity = "local-development"
	}
	if identity == "" {
		writeError(w, http.StatusUnauthorized, "tailscale_identity_required", "Tailscale-Identität fehlt.")
		return "", false
	}
	digest := sha256.Sum256([]byte(strings.ToLower(identity)))
	return hex.EncodeToString(digest[:]), true
}

func normalizedChatBody(body []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	var payload map[string]any
	if err := decoder.Decode(&payload); err != nil {
		return nil, errors.New("Anfrage enthält kein gültiges JSON.")
	}
	model, ok := payload["model"].(string)
	if !ok || strings.TrimSpace(model) == "" {
		return nil, errors.New("OpenRouter-Modell fehlt.")
	}
	payload["stream"] = false
	delete(payload, "stream_options")
	normalized, err := json.Marshal(payload)
	if err != nil {
		return nil, errors.New("Anfrage konnte nicht verarbeitet werden.")
	}
	return normalized, nil
}

func bearerToken(header string) (string, bool) {
	prefix, token, found := strings.Cut(strings.TrimSpace(header), " ")
	if !found || !strings.EqualFold(prefix, "Bearer") || strings.TrimSpace(token) == "" {
		return "", false
	}
	return strings.TrimSpace(token), true
}

func readLimited(reader io.Reader, maximum int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, maximum+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maximum {
		return nil, errors.New("response exceeds configured limit")
	}
	return data, nil
}

func makePublicJob(job Job) publicJob {
	return publicJob{
		ID:             job.ID,
		Status:         job.Status,
		CreatedAt:      job.CreatedAt,
		UpdatedAt:      job.UpdatedAt,
		ExpiresAt:      job.ExpiresAt,
		Attempt:        job.Attempt,
		UpstreamStatus: job.UpstreamStatus,
		ResponseBody:   job.ResponseBody,
		FailureCode:    job.FailureCode,
		FailureMessage: job.FailureMessage,
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": message,
		},
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func isLoopbackRequest(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func hashBytes(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func isRetryableStatus(status int) bool {
	return status == http.StatusRequestTimeout || status == http.StatusTooManyRequests || status >= 500
}

func clear(data []byte) {
	for index := range data {
		data[index] = 0
	}
}
