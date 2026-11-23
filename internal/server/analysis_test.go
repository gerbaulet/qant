package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAnalysisJobReturnsOneValidatedLabelResultAndDeletesItAfterAcknowledgement(t *testing.T) {
	t.Parallel()
	const secret = "phone-analysis-secret"
	var upstreamCalls int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamCalls, 1)
		if r.Header.Get("Authorization") != "Bearer "+secret {
			t.Errorf("unexpected authorization: %q", r.Header.Get("Authorization"))
		}
		body, _ := io.ReadAll(r.Body)
		if !bytes.Contains(body, []byte("nutrition_analysis_v12")) || !bytes.Contains(body, []byte("Locally recognized packaging text")) {
			t.Errorf("request does not contain the server-owned prompt and schema: %s", body)
		}
		if !bytes.Contains(body, []byte(`"usage":{"include":true}`)) {
			t.Errorf("request does not explicitly include usage accounting: %s", body)
		}
		writeOpenRouterAnalysisResponse(t, w, validAnalysisPayload(640))
	}))
	defer upstream.Close()

	dataDir := t.TempDir()
	application := newTestServer(t, dataDir, upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()
	request := validAnalysisRequest()
	request.RecognizedLabelText = []string{"Nährwerte pro 100 g, Energie 200 kcal, Protein 10 g"}

	job := createAnalysisJob(t, api.URL, "alice@example.com", secret, "analysis-request", request)
	job = waitForTerminalAnalysisJob(t, api.URL, "alice@example.com", job.ID)
	if job.Status != JobSucceeded || job.Result == nil || job.Result.Result == nil {
		t.Fatalf("expected successful analysis result, got %#v", job)
	}
	if got, _ := nutrientValue("energy", job.Result.Result.Nutrients); got != 640 {
		t.Fatalf("unexpected selected energy: %v", got)
	}
	if len(job.Result.Calls) != 1 || job.Result.Calls[0].Status != "succeeded" {
		t.Fatalf("unexpected call history: %#v", job.Result.Calls)
	}
	if cost := job.Result.Calls[0].CostUSD; cost == nil || *cost != 0.002 {
		t.Fatalf("missing request cost: %#v", job.Result.Calls[0])
	}
	if job.Result.PromptVersion != analysisPromptVersion || job.Result.PolicyVersion != analysisPolicyVersion {
		t.Fatalf("missing policy versions: %#v", job.Result)
	}
	if got := atomic.LoadInt32(&upstreamCalls); got != 1 {
		t.Fatalf("expected one upstream call, got %d", got)
	}

	persistedFiles, err := filepath.Glob(filepath.Join(dataDir, "*.json"))
	if err != nil || len(persistedFiles) != 1 {
		t.Fatalf("expected one persisted job: files=%v err=%v", persistedFiles, err)
	}
	persisted, err := os.ReadFile(persistedFiles[0])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(persisted, []byte(secret)) || bytes.Contains(persisted, []byte("private meal comment")) || bytes.Contains(persisted, []byte("AQIDBA==")) {
		t.Fatal("persisted analysis job contains a key, request comment, or request image")
	}

	acknowledgeAnalysisJob(t, api.URL, "alice@example.com", job.ID)
	if files, _ := filepath.Glob(filepath.Join(dataDir, "*.json")); len(files) != 0 {
		t.Fatalf("acknowledged analysis result was not deleted: %v", files)
	}
	response := getAnalysisJob(t, api.URL, "alice@example.com", job.ID, 0)
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("expected deleted job to be unavailable, got %d", response.StatusCode)
	}
}

func TestAnalysisJobRepairsOneInvalidResponseOnTheServer(t *testing.T) {
	t.Parallel()
	var calls int32
	var secondBody []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		call := atomic.AddInt32(&calls, 1)
		if call == 1 {
			invalid := validAnalysisPayload(1_000)
			for index := range invalid.Nutrients {
				if invalid.Nutrients[index].Identifier != "energy" {
					invalid.Nutrients[index].Value = 0
				}
			}
			for index := range invalid.Components[0].Nutrients {
				if invalid.Components[0].Nutrients[index].Identifier != "energy" {
					invalid.Components[0].Nutrients[index].Value = 0
				}
			}
			writeOpenRouterAnalysisResponse(t, w, invalid)
			return
		}
		secondBody = append([]byte(nil), body...)
		writeOpenRouterAnalysisResponse(t, w, validAnalysisPayload(600))
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()
	request := validAnalysisRequest()
	request.RecognizedLabelText = []string{"Nährwerte Energie 100 kcal pro 100 g"}

	job := createAnalysisJob(t, api.URL, "alice@example.com", "key", "repair-request", request)
	job = waitForTerminalAnalysisJob(t, api.URL, "alice@example.com", job.ID)
	if job.Status != JobSucceeded || job.Result == nil || len(job.Result.Calls) != 2 {
		t.Fatalf("expected corrected analysis with two calls, got %#v", job)
	}
	if job.Result.Calls[0].Status != "failed" || job.Result.Calls[0].ErrorMessage == nil || job.Result.Calls[1].Status != "succeeded" {
		t.Fatalf("unexpected correction history: %#v", job.Result.Calls)
	}
	for _, call := range job.Result.Calls {
		if call.CostUSD == nil || *call.CostUSD != 0.002 {
			t.Fatalf("missing cost for corrected call history: %#v", job.Result.Calls)
		}
	}
	if !bytes.Contains(secondBody, []byte("failed local validation")) || !bytes.Contains(secondBody, []byte("Kalorien und Makronährstoffe")) {
		t.Fatalf("repair prompt does not contain concrete validation feedback: %s", secondBody)
	}
}

func TestAnalysisJobPreservesUsageForUnreadableResponse(t *testing.T) {
	t.Parallel()
	var calls int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(map[string]any{
				"choices":  []any{map[string]any{"message": map[string]any{"content": "not-json"}}},
				"model":    "resolved/vision-model",
				"provider": "Example Provider",
				"usage": map[string]any{
					"prompt_tokens":     90,
					"completion_tokens": 10,
					"cost":              0.003,
				},
			}); err != nil {
				t.Fatal(err)
			}
			return
		}
		writeOpenRouterAnalysisResponse(t, w, validAnalysisPayload(600))
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	request := validAnalysisRequest()
	request.RecognizedLabelText = []string{"Nährwerte Energie 100 kcal pro 100 g"}
	job := createAnalysisJob(t, api.URL, "alice@example.com", "key", "unreadable-request", request)
	job = waitForTerminalAnalysisJob(t, api.URL, "alice@example.com", job.ID)
	if job.Status != JobSucceeded || job.Result == nil || len(job.Result.Calls) != 2 {
		t.Fatalf("expected repaired analysis with two calls, got %#v", job)
	}
	first := job.Result.Calls[0]
	if first.Status != "failed" || first.CostUSD == nil || *first.CostUSD != 0.003 {
		t.Fatalf("unreadable response lost its request cost: %#v", first)
	}
	if first.InputTokens == nil || *first.InputTokens != 90 || first.OutputTokens == nil || *first.OutputTokens != 10 {
		t.Fatalf("unreadable response lost its token usage: %#v", first)
	}
	if first.ModelIdentifier == nil || *first.ModelIdentifier != "resolved/vision-model" || first.ProviderIdentifier == nil || *first.ProviderIdentifier != "Example Provider" {
		t.Fatalf("unreadable response lost its routing metadata: %#v", first)
	}
}

func TestAnalysisJobRunsIndependentPlateEstimatesAndSelectsMedian(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	requestBodies := make([]string, 0, 3)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		text := string(body)
		mu.Lock()
		requestBodies = append(requestBodies, text)
		mu.Unlock()
		energy := 600.0
		if strings.Contains(text, "Independent visual estimate 2 of 3") {
			energy = 800
		} else if strings.Contains(text, "Independent visual estimate 3 of 3") {
			energy = 400
		}
		writeOpenRouterAnalysisResponse(t, w, validAnalysisPayload(energy))
	}))
	defer upstream.Close()

	application := newTestServer(t, t.TempDir(), upstream.URL)
	api := httptest.NewServer(application.Handler())
	defer api.Close()

	job := createAnalysisJob(t, api.URL, "alice@example.com", "key", "plate-request", validAnalysisRequest())
	job = waitForTerminalAnalysisJob(t, api.URL, "alice@example.com", job.ID)
	if job.Status != JobSucceeded || job.Result == nil || job.Result.Result == nil {
		t.Fatalf("expected successful plate analysis, got %#v", job)
	}
	energy, _ := nutrientValue("energy", job.Result.Result.Nutrients)
	if energy != 600 {
		t.Fatalf("expected median energy 600, got %v", energy)
	}
	if len(job.Result.Calls) != 3 {
		t.Fatalf("expected three recorded calls, got %#v", job.Result.Calls)
	}
	samples := map[int]bool{}
	for _, call := range job.Result.Calls {
		if call.SampleNumber != nil {
			samples[*call.SampleNumber] = true
		}
	}
	if !samples[1] || !samples[2] || !samples[3] {
		t.Fatalf("missing sample numbers: %#v", job.Result.Calls)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(requestBodies) != 3 {
		t.Fatalf("expected three upstream requests, got %d", len(requestBodies))
	}
}

func TestAnalysisValidationScalesLabelValuesBeforeDeterministicTotals(t *testing.T) {
	payload := validAnalysisPayload(400)
	weight := 250.0
	payload.EstimatedTotalWeightGrams = &weight
	payload.Components[0].EstimatedWeightGrams = &weight
	payload.Components[0].NutrientBasis = "per100Grams"
	for index := range payload.Components[0].Nutrients {
		payload.Components[0].Nutrients[index].Value *= 100 / weight
		payload.Components[0].Nutrients[index].Provenance = "label"
	}
	result := nutritionAnalysisResult{
		MealName:                  payload.MealName,
		EstimatedTotalWeightGrams: payload.EstimatedTotalWeightGrams,
		Confidence:                payload.Confidence,
		Nutrients:                 payload.Nutrients,
		Components:                payload.Components,
	}
	consumed := scalingComponentsToConsumedAmounts(result)
	if err := validateConsistency(consumed); err != nil {
		t.Fatal(err)
	}
	calculated := calculateTotals(consumed)
	energy, _ := nutrientValue("energy", calculated.Nutrients)
	if energy != 400 {
		t.Fatalf("expected scaled total 400 kcal, got %v", energy)
	}
	if calculated.Components[0].Nutrients[0].Provenance != "calculatedFromLabel" {
		t.Fatalf("label provenance was not converted: %#v", calculated.Components[0].Nutrients[0])
	}
}

func TestDefaultJobRetentionIsSevenDays(t *testing.T) {
	t.Setenv("QUANT_JOB_TTL", "")
	config, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if config.JobTTL != 7*24*time.Hour {
		t.Fatalf("expected seven-day retention, got %v", config.JobTTL)
	}
}

func validAnalysisRequest() analysisRequest {
	comment := "private meal comment"
	return analysisRequest{
		ProtocolVersion:             analysisProtocolVersion,
		RequestGroupIdentifier:      "11111111-2222-3333-4444-555555555555",
		Trigger:                     "initial",
		ModelIdentifier:             "example/vision-model",
		CostTier:                    "low",
		ProviderPreference:          "balanced",
		PreferredLanguageIdentifier: "de-DE",
		Images: []analysisImage{{
			Data:      []byte{1, 2, 3, 4},
			MediaType: "image/jpeg",
		}},
		UserComment:         &comment,
		AllowsClarification: true,
	}
}

func validAnalysisPayload(energy float64) nutritionAnalysisPayload {
	weight := 500.0
	nutrients := []analyzedNutrient{
		{Identifier: "energy", Value: energy, Unit: "kcal", Confidence: "medium", Provenance: "visualEstimate"},
		{Identifier: "protein", Value: 0, Unit: "g", Confidence: "medium", Provenance: "visualEstimate"},
		{Identifier: "carbohydrates", Value: energy / 4, Unit: "g", Confidence: "medium", Provenance: "visualEstimate"},
		{Identifier: "fat", Value: 0, Unit: "g", Confidence: "medium", Provenance: "visualEstimate"},
		{Identifier: "fiber", Value: 0, Unit: "g", Confidence: "medium", Provenance: "visualEstimate"},
		{Identifier: "alcohol", Value: 0, Unit: "g", Confidence: "medium", Provenance: "visualEstimate"},
	}
	return nutritionAnalysisPayload{
		MealName:                  "Testmahlzeit",
		EstimatedTotalWeightGrams: &weight,
		Confidence:                "medium",
		Nutrients:                 append([]analyzedNutrient(nil), nutrients...),
		Components: []analyzedFoodComponent{{
			Name:                 "Testmahlzeit",
			EstimatedWeightGrams: &weight,
			NutrientBasis:        "consumedAmount",
			Nutrients:            append([]analyzedNutrient(nil), nutrients...),
		}},
	}
}

func writeOpenRouterAnalysisResponse(t *testing.T, w http.ResponseWriter, payload nutritionAnalysisPayload) {
	t.Helper()
	content, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	response := map[string]any{
		"choices":  []any{map[string]any{"message": map[string]any{"content": string(content)}}},
		"model":    "resolved/vision-model",
		"provider": "Example Provider",
		"usage": map[string]any{
			"prompt_tokens":     120,
			"completion_tokens": 40,
			"cost":              0.002,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		t.Fatal(err)
	}
}

func createAnalysisJob(t *testing.T, apiURL, identity, apiKey, idempotencyKey string, request analysisRequest) publicAnalysisJob {
	t.Helper()
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	httpRequest, err := http.NewRequest(http.MethodPost, apiURL+"/api/v2/analysis-jobs", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	httpRequest.Header.Set("Tailscale-User-Login", identity)
	httpRequest.Header.Set("Authorization", "Bearer "+apiKey)
	httpRequest.Header.Set("Idempotency-Key", idempotencyKey)
	httpRequest.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(httpRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusAccepted && response.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("unexpected create status %d: %s", response.StatusCode, data)
	}
	var job publicAnalysisJob
	if err := json.NewDecoder(response.Body).Decode(&job); err != nil {
		t.Fatal(err)
	}
	return job
}

func waitForTerminalAnalysisJob(t *testing.T, apiURL, identity, id string) publicAnalysisJob {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		response := getAnalysisJob(t, apiURL, identity, id, 1)
		var job publicAnalysisJob
		err := json.NewDecoder(response.Body).Decode(&job)
		response.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if job.Status != JobRunning {
			return job
		}
	}
	t.Fatal("analysis job did not finish")
	return publicAnalysisJob{}
}

func getAnalysisJob(t *testing.T, apiURL, identity, id string, wait int) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodGet, apiURL+"/api/v2/analysis-jobs/"+id+"?wait="+strconv.Itoa(wait), nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Tailscale-User-Login", identity)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func acknowledgeAnalysisJob(t *testing.T, apiURL, identity, id string) {
	t.Helper()
	request, err := http.NewRequest(http.MethodDelete, apiURL+"/api/v2/analysis-jobs/"+id, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Tailscale-User-Login", identity)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("unexpected acknowledgement status: %d", response.StatusCode)
	}
}
