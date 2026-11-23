package server

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

func makeOpenRouterAnalysisBody(request analysisRequest) ([]byte, error) {
	content := []any{map[string]any{
		"type": "text",
		"text": analysisUserPrompt(request),
	}}
	for _, image := range request.Images {
		content = append(content, map[string]any{
			"type": "image_url",
			"image_url": map[string]any{
				"url": "data:" + image.MediaType + ";base64," + base64.StdEncoding.EncodeToString(image.Data),
			},
		})
	}
	provider := map[string]any{"require_parameters": true}
	if request.ProviderPreference == "faster" {
		provider["preferred_max_latency"] = map[string]any{"p90": 5}
	}
	body := map[string]any{
		"model":                 request.ModelIdentifier,
		"max_completion_tokens": 16_384,
		"temperature":           0,
		"stream":                false,
		"usage":                 map[string]any{"include": true},
		"provider":              provider,
		"messages": []any{
			map[string]any{
				"role":    "system",
				"content": analysisSystemPrompt(request.AllowsClarification, request.PreferredLanguageIdentifier),
			},
			map[string]any{
				"role":    "user",
				"content": content,
			},
		},
		"response_format": map[string]any{
			"type": "json_schema",
			"json_schema": map[string]any{
				"name":   fmt.Sprintf("nutrition_analysis_v%d", analysisPromptVersion),
				"strict": true,
				"schema": analysisResponseSchema(),
			},
		},
	}
	if request.ModelIdentifier == "openrouter/auto" || request.ModelIdentifier == "openrouter/auto-beta" {
		body["plugins"] = []any{map[string]any{
			"id":        "auto-router",
			"cost_tier": request.CostTier,
		}}
	}
	return json.Marshal(body)
}

func analysisSystemPrompt(allowsClarification bool, languageIdentifier string) string {
	clarificationRule := "Do not ask another clarification question. Return the best complete estimate from the available evidence."
	if allowsClarification {
		clarificationRule = "Ask at most one concise clarification question, and only when its answer could materially change the calorie estimate."
	}
	identifier := strings.ReplaceAll(strings.TrimSpace(languageIdentifier), "_", "-")
	if identifier == "" {
		identifier = "de"
	}
	language := "the language identified by BCP-47 tag " + identifier
	if strings.HasPrefix(strings.ToLower(identifier), "de") {
		language = "German (" + identifier + ")"
	}
	return strings.Join([]string{
		"Analyze the meal using every supplied image, the user's comment, and the locally recognized label text. Prefer explicit user quantities and readable label values over visual estimates.",
		"Return each distinct consumed component exactly once. For every component, provide its consumed weight and exactly these nutrients: energy, protein, carbohydrates, fat, fiber, and alcohol. Use kcal for energy and g for the other five values. Return zero alcohol for foods and drinks without alcohol. When alcohol by volume and consumed volume are known, calculate alcohol grams using an ethanol density of 0.789 g/ml. For readable labels or reliable standard values, return the values per 100 g and set nutrientBasis to per100Grams; the app performs the portion calculation. For a purely visual estimate, return values for the consumed amount and set nutrientBasis to consumedAmount.",
		"The app deterministically sums component weights and nutrients, so component values are authoritative. Also return meal totals for compatibility, using the same component values. Cross-check calories against protein, carbohydrates, fat, fiber, and alcohol (4/4/9/2/7 kcal per gram). Do not emit duplicate components or nutrient identifiers. Nutrient provenance must distinguish label, calculatedFromLabel, visualEstimate, textProvidedByUser, mixedEstimate, or unknown. Return only the JSON object required by the schema.",
		"Limit uncertaintySummary to at most 60 words.",
		"Write all user-facing text in " + language + ". This includes mealName, every components[].name, uncertaintySummary, and clarificationQuestion. Keep product and brand names unchanged. Keep schema keys and enum values exactly as specified.",
		clarificationRule,
	}, "\n")
}

func analysisUserPrompt(request analysisRequest) string {
	lines := make([]string, 0)
	if request.UserComment != nil && strings.TrimSpace(*request.UserComment) != "" {
		lines = append(lines, "Original user comment: "+strings.TrimSpace(*request.UserComment))
	} else {
		lines = append(lines, "No original user comment was provided.")
	}
	hasRecognizedLabels := false
	for _, text := range request.RecognizedLabelText {
		if strings.TrimSpace(text) != "" {
			hasRecognizedLabels = true
			break
		}
	}
	if hasRecognizedLabels {
		lines = append(lines, "Locally recognized packaging text (may contain OCR mistakes):")
		for index, text := range request.RecognizedLabelText {
			if strings.TrimSpace(text) != "" {
				lines = append(lines, fmt.Sprintf("Image %d:\n%s", index+1, text))
			}
		}
		lines = append(lines, "Use this text as reading assistance, verify it against the supplied images, and never treat package size as consumed amount unless the user says so.")
	}
	if request.PreviousAnalysis != nil {
		if data, err := json.Marshal(request.PreviousAnalysis); err == nil {
			lines = append(lines, "Baseline structured analysis (context to revise, not additional food consumed): "+string(data))
			lines = append(lines, "Evidence priority: current and earlier user clarifications first; then explicit original user text and readable labels; then visible image evidence; finally assumptions from the baseline analysis.")
			lines = append(lines, "Treat baseline quantities as existing assumptions, never as a second serving or extra ingredients.")
			lines = append(lines, "Baseline component names are descriptive only. Their omitted weights and nutrients must be regenerated consistently with the authoritative baseline total weight and total nutrients.")
		}
	}
	if len(request.ClarificationHistory) > 0 {
		if data, err := json.Marshal(request.ClarificationHistory); err == nil {
			lines = append(lines, "Earlier clarification history: "+string(data))
			lines = append(lines, "Preserve every confirmed fact in this history while applying the current answer.")
		}
	}
	if request.ClarificationAnswer != nil {
		lines = append(lines, "User's clarification answer: "+*request.ClarificationAnswer)
		lines = append(lines, "Revise the previous estimate using this answer. Replace the affected assumption; never add the confirmed amount on top of an amount already estimated for the same ingredient or portion.")
		lines = append(lines, "Keep unaffected ingredients and quantities unchanged. Recalculate the complete result so total weight, components, total nutrients, and component nutrients remain mutually consistent.")
		lines = append(lines, "If energy changes by both at least 100 kcal and at least 20% from the baseline, uncertaintySummary must specifically explain which newly confirmed ingredient or quantity caused the change. Do not reuse the earlier generic uncertainty text.")
	}
	if request.UserCorrection != nil {
		lines = append(lines, "User correction: "+*request.UserCorrection)
		lines = append(lines, "Generate a complete revised structured estimate. Apply the correction consistently across the meal name, components, total weight, and every nutrient.")
	}
	if request.RequestsBestEstimate {
		lines = append(lines, "The user chose to use the best estimate without further questions.")
	}
	if request.ValidationFeedback != nil {
		lines = append(lines, "The previous response failed local validation: "+*request.ValidationFeedback)
		lines = append(lines, "Return one corrected complete analysis. Fix the stated inconsistency and preserve all reliable image, label, and user evidence.")
	}
	if request.IndependentEstimateNumber != nil {
		lines = append(lines, fmt.Sprintf("Independent visual estimate %d of 3: estimate the meal afresh from the original evidence. Do not anchor on another model result.", *request.IndependentEstimateNumber))
	}
	return strings.Join(lines, "\n")
}

func analysisResponseSchema() map[string]any {
	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"properties": map[string]any{
			"mealName":                  map[string]any{"type": "string"},
			"estimatedTotalWeightGrams": map[string]any{"type": "number", "minimum": 0},
			"confidence":                enumSchema([]string{"low", "medium", "high"}),
			"uncertaintySummary":        map[string]any{"type": []string{"string", "null"}},
			"clarificationQuestion":     map[string]any{"type": []string{"string", "null"}},
			"nutrients": map[string]any{
				"type": "array", "minItems": 6, "maxItems": 6, "items": nutrientResponseSchema(),
			},
			"components": map[string]any{
				"type": "array", "minItems": 1,
				"items": map[string]any{
					"type": "object", "additionalProperties": false,
					"properties": map[string]any{
						"name":                 map[string]any{"type": "string"},
						"estimatedWeightGrams": map[string]any{"type": "number", "minimum": 0},
						"nutrientBasis":        enumSchema([]string{"per100Grams", "consumedAmount"}),
						"nutrients":            map[string]any{"type": "array", "minItems": 6, "maxItems": 6, "items": nutrientResponseSchema()},
					},
					"required": []string{"name", "estimatedWeightGrams", "nutrientBasis", "nutrients"},
				},
			},
		},
		"required": []string{"mealName", "estimatedTotalWeightGrams", "confidence", "uncertaintySummary", "clarificationQuestion", "nutrients", "components"},
	}
}

func nutrientResponseSchema() map[string]any {
	return map[string]any{
		"type": "object", "additionalProperties": false,
		"properties": map[string]any{
			"identifier": enumSchema(coreNutrientOrder),
			"value":      map[string]any{"type": "number", "minimum": 0},
			"unit":       enumSchema([]string{"kcal", "g", "mg", "µg"}),
			"confidence": enumSchema([]string{"low", "medium", "high"}),
			"provenance": enumSchema([]string{"label", "calculatedFromLabel", "visualEstimate", "textProvidedByUser", "mixedEstimate", "unknown"}),
		},
		"required": []string{"identifier", "value", "unit", "confidence", "provenance"},
	}
}

func enumSchema(values []string) map[string]any {
	return map[string]any{"type": "string", "enum": values}
}
