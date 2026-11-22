package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const maximumTransientAnalysisAttempts = 5

var measuredQuantityPattern = regexp.MustCompile(`(?i)(?:\d+(?:[.,]\d+)?|ein(?:e|en|er|em|es)?|zwei|drei|vier|fünf)\s*(?:mg|g|gramm|kg|kilogramm|ml|milliliter|cl|dl|l|liter|el|tl|esslöffel|teelöffel)\b`)

type malformedAnalysisError struct{}

func (malformedAnalysisError) Error() string {
	return "Die Ernährungsanalyse konnte nicht gelesen werden."
}

type upstreamAnalysisError struct {
	message   string
	retryable bool
}

func (e upstreamAnalysisError) Error() string { return e.message }

type analysisCallRecorder struct {
	mu                    sync.Mutex
	nextCallNumber        int
	calls                 []analysisCallSummary
	clarificationQuestion *string
	clarificationAnswer   *string
}

func (r *analysisCallRecorder) start() (int, time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextCallNumber++
	return r.nextCallNumber, time.Now().UTC()
}

func (r *analysisCallRecorder) record(summary analysisCallSummary) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, summary)
	sort.Slice(r.calls, func(i, j int) bool { return r.calls[i].CallNumber < r.calls[j].CallNumber })
}

func (r *analysisCallRecorder) snapshot() []analysisCallSummary {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]analysisCallSummary(nil), r.calls...)
}

func (s *Server) runAnalysisJob(id, apiKey string, request analysisRequest) {
	defer s.jobs.Done()
	defer func() { <-s.semaphore }()
	defer clearAnalysisRequest(&request)

	result, calls, err := s.performAnalysisOperation(context.Background(), apiKey, request)
	apiKey = ""
	payload := analysisOperationResult{
		Calls:         calls,
		PromptVersion: analysisPromptVersion,
		PolicyVersion: analysisPolicyVersion,
	}
	if err != nil {
		message := err.Error()
		payload.ErrorMessage = &message
		encoded, encodeError := json.Marshal(payload)
		if encodeError != nil {
			s.failJob(id, 0, nil, "analysis_encoding_failed", "Analyseergebnis konnte nicht gespeichert werden.", false)
			return
		}
		s.failJob(id, 0, encoded, "analysis_failed", message, false)
		return
	}
	payload.Result = &result
	encoded, err := json.Marshal(payload)
	if err != nil {
		s.failJob(id, 0, nil, "analysis_encoding_failed", "Analyseergebnis konnte nicht gespeichert werden.", false)
		return
	}
	if err := s.store.Succeed(id, http.StatusOK, encoded); err != nil {
		return
	}
}

func (s *Server) performAnalysisOperation(ctx context.Context, apiKey string, request analysisRequest) (nutritionAnalysisResult, []analysisCallSummary, error) {
	recorder := &analysisCallRecorder{
		clarificationAnswer: request.ClarificationAnswer,
	}
	if request.Trigger == "clarification" && request.PreviousAnalysis != nil {
		recorder.clarificationQuestion = request.PreviousAnalysis.ClarificationQuestion
	}
	firstSample := (*int)(nil)
	if request.Trigger == "initial" {
		value := 1
		firstSample = &value
	}
	first, err := s.requestValidAnalysis(ctx, apiKey, request, firstSample, recorder)
	if err != nil {
		return nutritionAnalysisResult{}, recorder.snapshot(), err
	}
	if request.Trigger != "initial" || !requiresAdditionalEstimates(request, first) {
		return first, recorder.snapshot(), nil
	}

	type sampleOutcome struct {
		result nutritionAnalysisResult
		err    error
	}
	outcomes := make(chan sampleOutcome, 2)
	for _, sampleNumber := range []int{2, 3} {
		number := sampleNumber
		go func() {
			independent := independentAnalysisRequest(request, number)
			result, err := s.requestValidAnalysis(ctx, apiKey, independent, &number, recorder)
			outcomes <- sampleOutcome{result: result, err: err}
		}()
	}
	valid := []nutritionAnalysisResult{first}
	for range 2 {
		outcome := <-outcomes
		if outcome.err == nil {
			valid = append(valid, outcome.result)
		}
	}
	if len(valid) != 3 {
		return first, recorder.snapshot(), nil
	}
	sort.Slice(valid, func(i, j int) bool {
		left, _ := nutrientValue("energy", valid[i].Nutrients)
		right, _ := nutrientValue("energy", valid[j].Nutrients)
		return left < right
	})
	return valid[1], recorder.snapshot(), nil
}

func (s *Server) requestValidAnalysis(ctx context.Context, apiKey string, original analysisRequest, sampleNumber *int, recorder *analysisCallRecorder) (nutritionAnalysisResult, error) {
	next := original
	attempt := 0
	transientFailures := 0
	usedCorrection := false
	for {
		attempt++
		callNumber, requestedAt := recorder.start()
		candidate, err := s.performAnalysisCall(ctx, apiKey, next, requestedAt)
		if err == nil {
			recorder.record(makeAnalysisCallSummary(callNumber, sampleNumber, attempt, "succeeded", &candidate, nil, requestedAt, recorder))
			return candidate, nil
		}
		recorder.record(makeAnalysisCallSummary(callNumber, sampleNumber, attempt, "failed", candidateOrNil(candidate), err, requestedAt, recorder))
		if isCorrectableAnalysisError(err) {
			if usedCorrection {
				return nutritionAnalysisResult{}, err
			}
			usedCorrection = true
			next = repairingAnalysisRequest(original, candidateOrNil(candidate), err.Error())
			continue
		}
		var upstreamError upstreamAnalysisError
		if !errors.As(err, &upstreamError) || !upstreamError.retryable {
			return nutritionAnalysisResult{}, err
		}
		transientFailures++
		if transientFailures >= maximumTransientAnalysisAttempts {
			return nutritionAnalysisResult{}, err
		}
		if err := s.retryDelay(ctx, attempt+1); err != nil {
			return nutritionAnalysisResult{}, err
		}
	}
}

func (s *Server) performAnalysisCall(ctx context.Context, apiKey string, request analysisRequest, requestedAt time.Time) (nutritionAnalysisResult, error) {
	body, err := makeOpenRouterAnalysisBody(request)
	if err != nil {
		return nutritionAnalysisResult{}, malformedAnalysisError{}
	}
	responseBody, err := s.sendAnalysisChatCompletion(ctx, apiKey, body)
	clear(body)
	if err != nil {
		return nutritionAnalysisResult{}, err
	}
	defer clear(responseBody)
	var response openRouterChatResponse
	if err := json.Unmarshal(responseBody, &response); err != nil || len(response.Choices) == 0 || response.Choices[0].Message.Content == "" {
		return nutritionAnalysisResult{}, malformedAnalysisError{}
	}
	contentBody := []byte(response.Choices[0].Message.Content)
	defer clear(contentBody)
	var payload nutritionAnalysisPayload
	if err := json.Unmarshal(contentBody, &payload); err != nil || !hasRequiredNutrientValues(contentBody) || !hasValidAnalysisEnums(payload) {
		return nutritionAnalysisResult{}, malformedAnalysisError{}
	}
	if !request.AllowsClarification && payload.ClarificationQuestion != nil && strings.TrimSpace(*payload.ClarificationQuestion) != "" {
		return nutritionAnalysisResult{}, malformedAnalysisError{}
	}
	result := normalizeAnalysis(nutritionAnalysisResult{
		MealName:                  payload.MealName,
		EstimatedTotalWeightGrams: payload.EstimatedTotalWeightGrams,
		Confidence:                payload.Confidence,
		UncertaintySummary:        payload.UncertaintySummary,
		ClarificationQuestion:     payload.ClarificationQuestion,
		Nutrients:                 payload.Nutrients,
		Components:                payload.Components,
		ModelIdentifier:           request.ModelIdentifier,
		ProviderIdentifier:        response.Provider,
		RequestMetrics: &analysisRequestMetrics{
			RequestedAt: requestedAt,
		},
	})
	if response.Model != nil {
		result.ModelIdentifier = *response.Model
	}
	if response.Usage != nil {
		result.RequestMetrics.InputTokens = response.Usage.PromptTokens
		result.RequestMetrics.OutputTokens = response.Usage.CompletionTokens
		result.RequestMetrics.CostUSD = response.Usage.Cost
	}
	if err := validateAnalysis(result); err != nil {
		return result, err
	}
	consumed := scalingComponentsToConsumedAmounts(result)
	if err := validateConsistency(consumed); err != nil {
		return result, err
	}
	result = calculateTotals(consumed)
	if err := validateAnalysis(result); err != nil {
		return result, err
	}
	if err := validateConsistency(result); err != nil {
		return result, err
	}
	if request.Trigger == "clarification" {
		if err := validateDrift(request.PreviousAnalysis, result); err != nil {
			return result, err
		}
	}
	return result, nil
}

func (s *Server) sendAnalysisChatCompletion(ctx context.Context, apiKey string, body []byte) ([]byte, error) {
	callContext, cancel := context.WithTimeout(ctx, s.config.UpstreamTimeout)
	defer cancel()
	select {
	case s.upstreamSemaphore <- struct{}{}:
		defer func() { <-s.upstreamSemaphore }()
	case <-callContext.Done():
		return nil, upstreamAnalysisError{message: "OpenRouter hat nicht rechtzeitig geantwortet.", retryable: true}
	}
	upstreamURL := *s.config.OpenRouterBaseURL
	upstreamURL.Path = strings.TrimRight(upstreamURL.Path, "/") + "/chat/completions"
	request, err := http.NewRequestWithContext(callContext, http.MethodPost, upstreamURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, upstreamAnalysisError{message: "OpenRouter-Anfrage konnte nicht erstellt werden.", retryable: false}
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "Quant-Server/2")
	response, err := s.client.Do(request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(callContext.Err(), context.DeadlineExceeded) {
			return nil, upstreamAnalysisError{message: "OpenRouter hat nicht rechtzeitig geantwortet.", retryable: true}
		}
		return nil, upstreamAnalysisError{message: "OpenRouter konnte nicht erreicht werden.", retryable: true}
	}
	defer response.Body.Close()
	responseBody, err := readLimited(response.Body, s.config.MaxResponseBytes)
	if err != nil {
		return nil, upstreamAnalysisError{message: "OpenRouter-Antwort ist zu groß.", retryable: false}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		message := openRouterErrorMessage(responseBody)
		if message == "" {
			message = "OpenRouter hat die Anfrage abgelehnt."
		}
		return nil, upstreamAnalysisError{
			message:   fmt.Sprintf("OpenRouter-Fehler %d: %s", response.StatusCode, message),
			retryable: isRetryableStatus(response.StatusCode),
		}
	}
	if !json.Valid(responseBody) {
		return nil, upstreamAnalysisError{message: "OpenRouter hat ungültiges JSON geliefert.", retryable: true}
	}
	return responseBody, nil
}

func makeAnalysisCallSummary(callNumber int, sampleNumber *int, attempt int, status string, result *nutritionAnalysisResult, callError error, requestedAt time.Time, recorder *analysisCallRecorder) analysisCallSummary {
	summary := analysisCallSummary{
		CallNumber:            callNumber,
		SampleNumber:          sampleNumber,
		AttemptNumber:         attempt,
		Status:                status,
		RequestedAt:           requestedAt,
		ClarificationQuestion: recorder.clarificationQuestion,
		ClarificationAnswer:   recorder.clarificationAnswer,
	}
	if result != nil {
		summary.ModelIdentifier = &result.ModelIdentifier
		summary.ProviderIdentifier = result.ProviderIdentifier
		if energy, ok := nutrientValue("energy", result.Nutrients); ok {
			summary.EnergyKilocalories = &energy
		}
		if result.ClarificationQuestion != nil {
			summary.ClarificationQuestion = result.ClarificationQuestion
		}
		if result.RequestMetrics != nil {
			summary.RequestedAt = result.RequestMetrics.RequestedAt
			summary.InputTokens = result.RequestMetrics.InputTokens
			summary.OutputTokens = result.RequestMetrics.OutputTokens
			summary.CostUSD = result.RequestMetrics.CostUSD
		}
	}
	if callError != nil {
		message := callError.Error()
		summary.ErrorMessage = &message
	}
	return summary
}

func candidateOrNil(candidate nutritionAnalysisResult) *nutritionAnalysisResult {
	if candidate.MealName == "" && candidate.ModelIdentifier == "" && len(candidate.Nutrients) == 0 && len(candidate.Components) == 0 {
		return nil
	}
	return &candidate
}

func isCorrectableAnalysisError(err error) bool {
	var validationError analysisValidationError
	var malformedError malformedAnalysisError
	return errors.As(err, &validationError) || errors.As(err, &malformedError)
}

func repairingAnalysisRequest(original analysisRequest, candidate *nutritionAnalysisResult, feedback string) analysisRequest {
	repaired := original
	if candidate != nil {
		repaired.PreviousAnalysis = candidate
	}
	repaired.ValidationFeedback = &feedback
	return repaired
}

func independentAnalysisRequest(original analysisRequest, number int) analysisRequest {
	request := original
	request.PreviousAnalysis = nil
	request.ClarificationHistory = nil
	request.ClarificationAnswer = nil
	request.UserCorrection = nil
	request.RequestsBestEstimate = true
	request.AllowsClarification = false
	request.ValidationFeedback = nil
	request.IndependentEstimateNumber = &number
	return request
}

func requiresAdditionalEstimates(request analysisRequest, result nutritionAnalysisResult) bool {
	return len(request.Images) > 0 &&
		(result.ClarificationQuestion == nil || strings.TrimSpace(*result.ClarificationQuestion) == "") &&
		!containsNutritionLabel(request.RecognizedLabelText) &&
		!measuredQuantityPattern.MatchString(optionalString(request.UserComment))
}

func containsNutritionLabel(values []string) bool {
	text := foldedText(strings.Join(values, "\n"))
	hasDigit := strings.ContainsAny(text, "0123456789")
	if !hasDigit {
		return false
	}
	groups := [][]string{
		{"nahrwert", "nutrition"}, {"energie", "energy", "kcal", "kj"},
		{"protein", "eiweiss"}, {"kohlenhydrat", "carbohydrate"},
		{"fett", "fat"}, {"pro 100", "per 100", "100 g", "100g"},
	}
	matches := 0
	for _, group := range groups {
		for _, candidate := range group {
			if strings.Contains(text, candidate) {
				matches++
				break
			}
		}
	}
	return matches >= 2
}

func optionalString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func openRouterErrorMessage(body []byte) string {
	var payload struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &payload) == nil {
		return strings.TrimSpace(payload.Error.Message)
	}
	return ""
}

func hasRequiredNutrientValues(body []byte) bool {
	var payload struct {
		Nutrients  []map[string]json.RawMessage `json:"nutrients"`
		Components []struct {
			Nutrients []map[string]json.RawMessage `json:"nutrients"`
		} `json:"components"`
	}
	if json.Unmarshal(body, &payload) != nil {
		return false
	}
	for _, nutrient := range payload.Nutrients {
		if _, ok := nutrient["value"]; !ok {
			return false
		}
	}
	for _, component := range payload.Components {
		for _, nutrient := range component.Nutrients {
			if _, ok := nutrient["value"]; !ok {
				return false
			}
		}
	}
	return true
}

func hasValidAnalysisEnums(payload nutritionAnalysisPayload) bool {
	if !isOneOf(payload.Confidence, "low", "medium", "high") {
		return false
	}
	for _, nutrient := range payload.Nutrients {
		if !hasValidNutrientEnums(nutrient) {
			return false
		}
	}
	for _, component := range payload.Components {
		if !isOneOf(component.NutrientBasis, "per100Grams", "consumedAmount") {
			return false
		}
		for _, nutrient := range component.Nutrients {
			if !hasValidNutrientEnums(nutrient) {
				return false
			}
		}
	}
	return true
}

func hasValidNutrientEnums(nutrient analyzedNutrient) bool {
	return isOneOf(nutrient.Identifier, coreNutrientOrder...) &&
		isOneOf(nutrient.Unit, "kcal", "g", "mg", "µg") &&
		isOneOf(nutrient.Confidence, "low", "medium", "high") &&
		isOneOf(nutrient.Provenance, "label", "calculatedFromLabel", "visualEstimate", "textProvidedByUser", "mixedEstimate", "unknown")
}

func isOneOf(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if value == candidate {
			return true
		}
	}
	return false
}

func defaultAnalysisRetryDelay(ctx context.Context, attempt int) error {
	exponent := attempt - 2
	if exponent < 0 {
		exponent = 0
	}
	if exponent > 6 {
		exponent = 6
	}
	duration := time.Duration(1<<exponent) * time.Second
	if duration > 60*time.Second {
		duration = 60 * time.Second
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func clearAnalysisRequest(request *analysisRequest) {
	for index := range request.Images {
		clear(request.Images[index].Data)
	}
	request.Images = nil
	request.RecognizedLabelText = nil
	request.ClarificationHistory = nil
	request.UserComment = nil
	request.ClarificationAnswer = nil
	request.UserCorrection = nil
	request.PreviousAnalysis = nil
}
