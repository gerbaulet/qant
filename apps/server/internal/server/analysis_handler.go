package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const maximumAnalysisWait = 25 * time.Second

func (s *Server) handleAnalysisJobs(w http.ResponseWriter, r *http.Request) {
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
	var request analysisRequest
	if err := json.Unmarshal(body, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_analysis_request", "Analyseanfrage enthält kein gültiges JSON.")
		return
	}
	if message := validateAnalysisRequest(request); message != "" {
		writeError(w, http.StatusBadRequest, "invalid_analysis_request", message)
		return
	}
	job, shouldStart, err := s.store.CreateOrReuse(ownerHash, idempotencyKey, hashBytes(body))
	if errors.Is(err, ErrIdempotencyConflict) {
		writeError(w, http.StatusConflict, "idempotency_conflict", err.Error())
		return
	}
	if err != nil {
		log.Printf("creating analysis job failed: %v", err)
		writeError(w, http.StatusInternalServerError, "job_storage_failed", "Analyseauftrag konnte nicht gespeichert werden.")
		return
	}
	if shouldStart {
		log.Printf("analysis job accepted")
		slotHandedOff = true
		s.jobs.Add(1)
		go s.runAnalysisJob(job.ID, apiKey, request)
	} else {
		clearAnalysisRequest(&request)
	}
	status := http.StatusOK
	if job.Status == JobRunning {
		status = http.StatusAccepted
		w.Header().Set("Retry-After", "1")
	}
	writeJSON(w, status, makePublicAnalysisJob(job))
}

func (s *Server) handleAnalysisJob(w http.ResponseWriter, r *http.Request) {
	ownerHash, ok := s.authenticateRequest(w, r)
	if !ok {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/v2/analysis-jobs/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "job_not_found", "Analyseauftrag wurde nicht gefunden.")
		return
	}
	switch r.Method {
	case http.MethodGet:
		wait := requestedWait(r)
		var job Job
		var found bool
		if wait > 0 {
			ctx, cancel := context.WithTimeout(r.Context(), wait)
			defer cancel()
			job, found = s.store.Wait(ctx, id, ownerHash)
		} else {
			job, found = s.store.Get(id, ownerHash)
		}
		if !found {
			writeError(w, http.StatusNotFound, "job_not_found", "Analyseauftrag wurde nicht gefunden oder ist abgelaufen.")
			return
		}
		if job.Status == JobRunning {
			w.Header().Set("Retry-After", "1")
		}
		writeJSON(w, http.StatusOK, makePublicAnalysisJob(job))
	case http.MethodDelete:
		_, err := s.store.Acknowledge(id, ownerHash)
		if err != nil {
			log.Printf("acknowledging analysis job failed: %v", err)
			writeError(w, http.StatusInternalServerError, "job_storage_failed", "Analyseauftrag konnte nicht gelöscht werden.")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "Methode nicht erlaubt.")
	}
}

func validateAnalysisRequest(request analysisRequest) string {
	if request.ProtocolVersion != analysisProtocolVersion {
		return "Nicht unterstützte Analyseprotokoll-Version."
	}
	if strings.TrimSpace(request.RequestGroupIdentifier) == "" || len(request.RequestGroupIdentifier) > 100 {
		return "Analysekennung fehlt oder ist ungültig."
	}
	if strings.TrimSpace(request.ModelIdentifier) == "" || !strings.Contains(request.ModelIdentifier, "/") {
		return "OpenRouter-Modell fehlt oder ist ungültig."
	}
	validTriggers := map[string]bool{"initial": true, "retry": true, "clarification": true, "correction": true, "bestEstimate": true}
	if !validTriggers[request.Trigger] {
		return "Analyseauslöser ist ungültig."
	}
	validCostTiers := map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
	if !validCostTiers[request.CostTier] {
		return "Kostenstufe ist ungültig."
	}
	if request.ProviderPreference != "balanced" && request.ProviderPreference != "faster" {
		return "Providerpräferenz ist ungültig."
	}
	if len(request.Images) > 10 {
		return "Zu viele Bilder."
	}
	for _, image := range request.Images {
		if len(image.Data) == 0 || len(image.MediaType) > 100 || !strings.HasPrefix(image.MediaType, "image/") {
			return "Ein Bild ist leer oder hat einen ungültigen Medientyp."
		}
	}
	return ""
}

func requestedWait(r *http.Request) time.Duration {
	seconds, err := strconv.Atoi(r.URL.Query().Get("wait"))
	if err != nil || seconds <= 0 {
		return 0
	}
	wait := time.Duration(seconds) * time.Second
	if wait > maximumAnalysisWait {
		return maximumAnalysisWait
	}
	return wait
}

func makePublicAnalysisJob(job Job) publicAnalysisJob {
	public := publicAnalysisJob{
		ID:             job.ID,
		Status:         job.Status,
		CreatedAt:      job.CreatedAt,
		UpdatedAt:      job.UpdatedAt,
		ExpiresAt:      job.ExpiresAt,
		Attempt:        job.Attempt,
		FailureCode:    job.FailureCode,
		FailureMessage: job.FailureMessage,
		Retryable:      job.Retryable,
	}
	if len(job.ResponseBody) > 0 {
		var result analysisOperationResult
		if json.Unmarshal(job.ResponseBody, &result) == nil {
			public.Result = &result
		}
	}
	return public
}
