package server

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

var coreNutrientOrder = []string{"energy", "protein", "carbohydrates", "fat", "fiber", "alcohol"}

type analysisValidationError struct {
	reason string
}

func (e analysisValidationError) Error() string {
	return "Die Ernährungsanalyse enthielt widersprüchliche Werte: " + e.reason
}

func invalidAnalysis(reason string) error {
	return analysisValidationError{reason: reason}
}

func normalizeAnalysis(result nutritionAnalysisResult) nutritionAnalysisResult {
	result.MealName = strings.TrimSpace(result.MealName)
	result.UncertaintySummary = normalizedOptionalText(result.UncertaintySummary)
	result.ClarificationQuestion = normalizedOptionalText(result.ClarificationQuestion)
	result.Nutrients = normalizeNutrients(result.Nutrients)
	seenNames := make(map[string]bool)
	components := make([]analyzedFoodComponent, 0, len(result.Components))
	for _, component := range result.Components {
		component.Name = strings.TrimSpace(component.Name)
		if component.Name == "" {
			continue
		}
		comparisonName := foldedText(component.Name)
		if seenNames[comparisonName] {
			continue
		}
		seenNames[comparisonName] = true
		component.Nutrients = normalizeNutrients(component.Nutrients)
		components = append(components, component)
	}
	result.Components = components
	return result
}

func normalizedOptionalText(value *string) *string {
	if value == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func normalizeNutrients(values []analyzedNutrient) []analyzedNutrient {
	grouped := make(map[string][]analyzedNutrient)
	for _, nutrient := range values {
		grouped[nutrient.Identifier] = append(grouped[nutrient.Identifier], nutrient)
	}
	result := make([]analyzedNutrient, 0, len(grouped))
	for identifier, candidates := range grouped {
		selected := candidates[0]
		expected := expectedUnit(identifier)
		for _, candidate := range candidates {
			if candidate.Unit == expected {
				selected = candidate
				break
			}
		}
		selected.Unit = expected
		result = append(result, selected)
	}
	sort.Slice(result, func(i, j int) bool {
		return nutrientOrder(result[i].Identifier) < nutrientOrder(result[j].Identifier)
	})
	return result
}

func nutrientOrder(identifier string) int {
	for index, candidate := range coreNutrientOrder {
		if identifier == candidate {
			return index
		}
	}
	return len(coreNutrientOrder) + 1
}

func expectedUnit(identifier string) string {
	if identifier == "energy" {
		return "kcal"
	}
	return "g"
}

func validateAnalysis(result nutritionAnalysisResult) error {
	if strings.TrimSpace(result.MealName) == "" {
		return invalidAnalysis("Der Name der Mahlzeit fehlt.")
	}
	if result.UncertaintySummary != nil && len(strings.Fields(*result.UncertaintySummary)) > 60 {
		return invalidAnalysis("Die Angabe zur Schätzsicherheit umfasst mehr als 60 Wörter.")
	}
	if err := validateOptionalNonnegative(result.EstimatedTotalWeightGrams, "Das Gesamtgewicht"); err != nil {
		return err
	}
	if err := validateNutrients(result.Nutrients); err != nil {
		return err
	}
	if len(result.Components) == 0 {
		return invalidAnalysis("Mindestens ein Bestandteil fehlt.")
	}
	for _, component := range result.Components {
		if strings.TrimSpace(component.Name) == "" {
			return invalidAnalysis("Der Name eines Bestandteils fehlt.")
		}
		if err := validateOptionalNonnegative(component.EstimatedWeightGrams, "Das Gewicht eines Bestandteils"); err != nil {
			return err
		}
		if err := validateNutrients(component.Nutrients); err != nil {
			return err
		}
	}
	return nil
}

func validateOptionalNonnegative(value *float64, field string) error {
	if value == nil {
		return nil
	}
	if math.IsNaN(*value) || math.IsInf(*value, 0) || *value < 0 {
		return invalidAnalysis(field + " ist negativ oder keine gültige Zahl.")
	}
	return nil
}

func validateNutrients(nutrients []analyzedNutrient) error {
	identifiers := make(map[string]bool)
	for _, nutrient := range nutrients {
		if identifiers[nutrient.Identifier] {
			return invalidAnalysis("Ein Nährwert wurde mehrfach ausgegeben.")
		}
		identifiers[nutrient.Identifier] = true
	}
	for _, required := range coreNutrientOrder {
		if !identifiers[required] {
			return invalidAnalysis("Mindestens ein erforderlicher Kernnährwert fehlt.")
		}
	}
	for _, nutrient := range nutrients {
		if math.IsNaN(nutrient.Value) || math.IsInf(nutrient.Value, 0) || nutrient.Value < 0 {
			return invalidAnalysis("Ein Nährwert ist negativ oder keine gültige Zahl.")
		}
		if expectedUnit(nutrient.Identifier) != nutrient.Unit {
			return invalidAnalysis("Ein Nährwert hat die falsche Einheit.")
		}
	}
	return nil
}

func validateConsistency(result nutritionAnalysisResult) error {
	if err := validateUniqueComponents(result.Components); err != nil {
		return err
	}
	if result.EstimatedTotalWeightGrams != nil && allComponentWeightsPresent(result.Components) {
		componentWeight := 0.0
		for _, component := range result.Components {
			componentWeight += *component.EstimatedWeightGrams
		}
		tolerance := math.Max(50, *result.EstimatedTotalWeightGrams*0.25)
		if math.Abs(componentWeight-*result.EstimatedTotalWeightGrams) > tolerance {
			return invalidAnalysis("Bestandteilmengen und Gesamtgewicht stimmen nicht überein.")
		}
	}
	if totalEnergy, ok := nutrientValue("energy", result.Nutrients); ok && allComponentNutrientsPresent("energy", result.Components) {
		componentEnergy := 0.0
		for _, component := range result.Components {
			value, _ := nutrientValue("energy", component.Nutrients)
			componentEnergy += value
		}
		tolerance := math.Max(75, totalEnergy*0.25)
		if math.Abs(componentEnergy-totalEnergy) > tolerance {
			return invalidAnalysis("Kalorien der Bestandteile und Gesamtkalorien stimmen nicht überein.")
		}
	}
	energy, energyOK := nutrientValue("energy", result.Nutrients)
	protein, proteinOK := nutrientValue("protein", result.Nutrients)
	carbohydrates, carbohydratesOK := nutrientValue("carbohydrates", result.Nutrients)
	fat, fatOK := nutrientValue("fat", result.Nutrients)
	fiber, fiberOK := nutrientValue("fiber", result.Nutrients)
	alcohol, alcoholOK := nutrientValue("alcohol", result.Nutrients)
	if energyOK && proteinOK && carbohydratesOK && fatOK && fiberOK && alcoholOK {
		macroEnergy := protein*4 + carbohydrates*4 + fat*9 + fiber*2 + alcohol*7
		tolerance := math.Max(120, energy*0.35)
		if math.Abs(macroEnergy-energy) > tolerance {
			return invalidAnalysis("Kalorien und Makronährstoffe stimmen nicht überein.")
		}
	}
	if err := validateEnergyDensity(result.EstimatedTotalWeightGrams, nutrientPointer("energy", result.Nutrients), "Die Gesamtmenge"); err != nil {
		return err
	}
	for _, component := range result.Components {
		if err := validateEnergyDensity(component.EstimatedWeightGrams, nutrientPointer("energy", component.Nutrients), fmt.Sprintf("Der Bestandteil „%s“", component.Name)); err != nil {
			return err
		}
	}
	return nil
}

func validateUniqueComponents(components []analyzedFoodComponent) error {
	seen := make(map[string]bool)
	for _, component := range components {
		name := foldedText(component.Name)
		if seen[name] {
			return invalidAnalysis("Ein Bestandteil wurde mehrfach ausgegeben.")
		}
		seen[name] = true
	}
	return nil
}

func validateEnergyDensity(weight, energy *float64, field string) error {
	if weight == nil || energy == nil || *weight <= 0 {
		return nil
	}
	if *energy > *weight*9.5+25 {
		return invalidAnalysis(field + " enthält mehr Energie, als bei diesem Gewicht physikalisch plausibel ist.")
	}
	return nil
}

func scalingComponentsToConsumedAmounts(result nutritionAnalysisResult) nutritionAnalysisResult {
	components := make([]analyzedFoodComponent, 0, len(result.Components))
	for _, component := range result.Components {
		converted := component
		converted.NutrientBasis = "consumedAmount"
		converted.Nutrients = make([]analyzedNutrient, 0, len(component.Nutrients))
		for _, nutrient := range component.Nutrients {
			if nutrientOrder(nutrient.Identifier) >= len(coreNutrientOrder) {
				continue
			}
			if component.NutrientBasis == "per100Grams" && component.EstimatedWeightGrams != nil {
				nutrient.Value *= *component.EstimatedWeightGrams / 100
				if nutrient.Provenance == "label" {
					nutrient.Provenance = "calculatedFromLabel"
				}
			}
			converted.Nutrients = append(converted.Nutrients, nutrient)
		}
		components = append(components, converted)
	}
	result.Components = components
	return result
}

func calculateTotals(result nutritionAnalysisResult) nutritionAnalysisResult {
	result = scalingComponentsToConsumedAmounts(result)
	canSum := len(result.Components) > 0
	for _, component := range result.Components {
		for _, identifier := range coreNutrientOrder {
			if _, ok := nutrientValue(identifier, component.Nutrients); !ok {
				canSum = false
			}
		}
	}
	if canSum {
		nutrients := make([]analyzedNutrient, 0, len(coreNutrientOrder))
		for _, identifier := range coreNutrientOrder {
			values := make([]analyzedNutrient, 0, len(result.Components))
			for _, component := range result.Components {
				for _, nutrient := range component.Nutrients {
					if nutrient.Identifier == identifier {
						values = append(values, nutrient)
						break
					}
				}
			}
			selected := values[0]
			selected.Value = 0
			for _, value := range values {
				selected.Value += value.Value
			}
			selected.Confidence = lowestConfidence(values)
			selected.Provenance = combinedProvenance(values)
			nutrients = append(nutrients, selected)
		}
		result.Nutrients = nutrients
	}
	if len(result.Components) > 0 && allComponentWeightsPresent(result.Components) {
		total := 0.0
		for _, component := range result.Components {
			total += *component.EstimatedWeightGrams
		}
		result.EstimatedTotalWeightGrams = &total
	}
	return result
}

func validateDrift(previous *nutritionAnalysisResult, revised nutritionAnalysisResult) error {
	if previous == nil {
		return nil
	}
	previousEnergy, previousOK := nutrientValue("energy", previous.Nutrients)
	revisedEnergy, revisedOK := nutrientValue("energy", revised.Nutrients)
	if !previousOK || !revisedOK {
		return nil
	}
	absoluteChange := math.Abs(revisedEnergy - previousEnergy)
	relativeChange := absoluteChange / math.Max(math.Abs(previousEnergy), 1)
	if absoluteChange < 100 || relativeChange < 0.20 {
		return nil
	}
	explanation := ""
	if revised.UncertaintySummary != nil {
		explanation = strings.TrimSpace(*revised.UncertaintySummary)
	}
	previousSummary := ""
	if previous.UncertaintySummary != nil {
		previousSummary = strings.TrimSpace(*previous.UncertaintySummary)
	}
	if len(explanation) < 20 || explanation == previousSummary {
		return invalidAnalysis("material calorie change lacks a specific explanation")
	}
	return nil
}

func nutrientValue(identifier string, nutrients []analyzedNutrient) (float64, bool) {
	for _, nutrient := range nutrients {
		if nutrient.Identifier == identifier {
			return nutrient.Value, true
		}
	}
	return 0, false
}

func nutrientPointer(identifier string, nutrients []analyzedNutrient) *float64 {
	value, ok := nutrientValue(identifier, nutrients)
	if !ok {
		return nil
	}
	return &value
}

func allComponentWeightsPresent(components []analyzedFoodComponent) bool {
	if len(components) == 0 {
		return false
	}
	for _, component := range components {
		if component.EstimatedWeightGrams == nil {
			return false
		}
	}
	return true
}

func allComponentNutrientsPresent(identifier string, components []analyzedFoodComponent) bool {
	if len(components) == 0 {
		return false
	}
	for _, component := range components {
		if _, ok := nutrientValue(identifier, component.Nutrients); !ok {
			return false
		}
	}
	return true
}

func lowestConfidence(values []analyzedNutrient) string {
	result := "high"
	for _, value := range values {
		if value.Confidence == "low" {
			return "low"
		}
		if value.Confidence == "medium" {
			result = "medium"
		}
	}
	return result
}

func combinedProvenance(values []analyzedNutrient) string {
	if len(values) == 0 {
		return "mixedEstimate"
	}
	first := values[0].Provenance
	for _, value := range values[1:] {
		if value.Provenance != first {
			return "mixedEstimate"
		}
	}
	return first
}

func foldedText(value string) string {
	replacer := strings.NewReplacer("ä", "a", "ö", "o", "ü", "u", "ß", "ss", "é", "e", "è", "e", "á", "a", "à", "a")
	return replacer.Replace(strings.ToLower(strings.TrimSpace(value)))
}
