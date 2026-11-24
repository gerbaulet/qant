package server

import "time"

const (
	analysisProtocolVersion = 1
	analysisPolicyVersion   = 1
	analysisPromptVersion   = 12
)

type analysisRequest struct {
	ProtocolVersion             int                      `json:"protocol_version"`
	RequestGroupIdentifier      string                   `json:"request_group_identifier"`
	Trigger                     string                   `json:"trigger"`
	ModelIdentifier             string                   `json:"model_identifier"`
	CostTier                    string                   `json:"cost_tier"`
	ProviderPreference          string                   `json:"provider_preference"`
	PreferredLanguageIdentifier string                   `json:"preferred_language_identifier"`
	Images                      []analysisImage          `json:"images"`
	UserComment                 *string                  `json:"user_comment"`
	PreviousAnalysis            *nutritionAnalysisResult `json:"previous_analysis"`
	ClarificationHistory        []clarificationExchange  `json:"clarification_history"`
	ClarificationAnswer         *string                  `json:"clarification_answer"`
	UserCorrection              *string                  `json:"user_correction"`
	RequestsBestEstimate        bool                     `json:"requests_best_estimate"`
	AllowsClarification         bool                     `json:"allows_clarification"`
	RecognizedLabelText         []string                 `json:"recognized_label_text"`
	ValidationFeedback          *string                  `json:"-"`
	IndependentEstimateNumber   *int                     `json:"-"`
}

type analysisImage struct {
	Data      []byte `json:"data"`
	MediaType string `json:"media_type"`
}

type clarificationExchange struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

type analyzedNutrient struct {
	Identifier string  `json:"identifier"`
	Value      float64 `json:"value"`
	Unit       string  `json:"unit"`
	Confidence string  `json:"confidence"`
	Provenance string  `json:"provenance"`
}

type analyzedFoodComponent struct {
	Name                 string             `json:"name"`
	EstimatedWeightGrams *float64           `json:"estimatedWeightGrams"`
	NutrientBasis        string             `json:"nutrientBasis"`
	Nutrients            []analyzedNutrient `json:"nutrients"`
}

type analysisRequestMetrics struct {
	RequestedAt  time.Time `json:"requestedAt"`
	InputTokens  *int      `json:"inputTokens"`
	OutputTokens *int      `json:"outputTokens"`
	CostUSD      *float64  `json:"costUSD"`
}

type nutritionAnalysisResult struct {
	MealName                  string                  `json:"mealName"`
	EstimatedTotalWeightGrams *float64                `json:"estimatedTotalWeightGrams"`
	Confidence                string                  `json:"confidence"`
	UncertaintySummary        *string                 `json:"uncertaintySummary"`
	ClarificationQuestion     *string                 `json:"clarificationQuestion"`
	Nutrients                 []analyzedNutrient      `json:"nutrients"`
	Components                []analyzedFoodComponent `json:"components"`
	ModelIdentifier           string                  `json:"modelIdentifier"`
	ProviderIdentifier        *string                 `json:"providerIdentifier"`
	RequestMetrics            *analysisRequestMetrics `json:"requestMetrics"`
}

type analysisCallSummary struct {
	CallNumber            int       `json:"call_number"`
	SampleNumber          *int      `json:"sample_number"`
	AttemptNumber         int       `json:"attempt_number"`
	Status                string    `json:"status"`
	ModelIdentifier       *string   `json:"model_identifier"`
	ProviderIdentifier    *string   `json:"provider_identifier"`
	EnergyKilocalories    *float64  `json:"energy_kilocalories"`
	ErrorMessage          *string   `json:"error_message"`
	RequestedAt           time.Time `json:"requested_at"`
	ClarificationQuestion *string   `json:"clarification_question"`
	ClarificationAnswer   *string   `json:"clarification_answer"`
	InputTokens           *int      `json:"input_tokens"`
	OutputTokens          *int      `json:"output_tokens"`
	CostUSD               *float64  `json:"cost_usd"`
}

type analysisOperationResult struct {
	Result        *nutritionAnalysisResult `json:"result,omitempty"`
	Calls         []analysisCallSummary    `json:"calls"`
	PromptVersion int                      `json:"prompt_version"`
	PolicyVersion int                      `json:"policy_version"`
	ErrorMessage  *string                  `json:"error_message,omitempty"`
}

type publicAnalysisJob struct {
	ID             string                   `json:"id"`
	Status         JobStatus                `json:"status"`
	CreatedAt      time.Time                `json:"created_at"`
	UpdatedAt      time.Time                `json:"updated_at"`
	ExpiresAt      time.Time                `json:"expires_at"`
	Attempt        int                      `json:"attempt"`
	Result         *analysisOperationResult `json:"result,omitempty"`
	FailureCode    string                   `json:"failure_code,omitempty"`
	FailureMessage string                   `json:"failure_message,omitempty"`
	Retryable      bool                     `json:"retryable,omitempty"`
}

type openRouterChatResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Model    *string `json:"model"`
	Provider *string `json:"provider"`
	Usage    *struct {
		PromptTokens     *int     `json:"prompt_tokens"`
		CompletionTokens *int     `json:"completion_tokens"`
		Cost             *float64 `json:"cost"`
	} `json:"usage"`
}

type nutritionAnalysisPayload struct {
	MealName                  string                  `json:"mealName"`
	EstimatedTotalWeightGrams *float64                `json:"estimatedTotalWeightGrams"`
	Confidence                string                  `json:"confidence"`
	UncertaintySummary        *string                 `json:"uncertaintySummary"`
	ClarificationQuestion     *string                 `json:"clarificationQuestion"`
	Nutrients                 []analyzedNutrient      `json:"nutrients"`
	Components                []analyzedFoodComponent `json:"components"`
}
