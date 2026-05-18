package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"time"
)

type CompareRequest struct {
	CurrentPlan   Plan    `json:"current_plan"`
	CandidatePlan Plan    `json:"candidate_plan"`
	BatteryCost   float64 `json:"battery_cost"`
	PaybackYears  float64 `json:"payback_years"`
}

type PlanCostBreakdown struct {
	PlanName       string  `json:"plan_name"`
	AnnualCost     float64 `json:"annual_cost"`
	AnnualEnergy   float64 `json:"annual_energy"`
	AnnualSupply   float64 `json:"annual_supply"`
	AnnualFeedIn   float64 `json:"annual_feed_in_credit"`
	DaysSimulated  int     `json:"days_simulated"`
	GridImportKWh  float64 `json:"grid_import_kwh"`
	SolarExportKWh float64 `json:"solar_export_kwh"`
}

type PlanComparison struct {
	Current                     PlanCostBreakdown `json:"current"`
	Candidate                   PlanCostBreakdown `json:"candidate"`
	AnnualDelta                 float64           `json:"annual_delta"`
	HorizonYears                float64           `json:"horizon_years"`
	HorizonDelta                float64           `json:"horizon_delta"`
	Verdict                     string            `json:"verdict"`
	BatteryAnnualDischargeValue float64           `json:"battery_annual_discharge_value"`
	BatteryPaybackYears         float64           `json:"battery_payback_years"`
	Analysis                    []string          `json:"analysis"`
}

func handleComparePlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req CompareRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	data, err := store.LoadUsageData()
	if err != nil || len(data) == 0 {
		http.Error(w, "No usage data loaded. Upload CSV, generate sample data, or import from InfluxDB first.", http.StatusBadRequest)
		return
	}
	cmp := ComparePlans(data, req)
	jsonResp(w, cmp)
}

func ComparePlans(data []UsageRecord, req CompareRequest) PlanComparison {
	current := CalculatePlanCost(data, req.CurrentPlan)
	candidate := CalculatePlanCost(data, req.CandidatePlan)
	delta := candidate.AnnualCost - current.AnnualCost

	batteryAnnualValue := calculateBatteryDischargeValue(data, req.CurrentPlan)
	batteryPayback := 0.0
	if req.BatteryCost > 0 && batteryAnnualValue > 0 {
		batteryPayback = req.BatteryCost / batteryAnnualValue
	}

	horizon := req.PaybackYears
	if horizon <= 0 && batteryPayback > 0 {
		horizon = batteryPayback
	}
	if horizon <= 0 {
		horizon = 10
	}

	verdict := "same"
	if delta < -0.01 {
		verdict = "better"
	} else if delta > 0.01 {
		verdict = "worse"
	}

	analysis := []string{}
	switch verdict {
	case "better":
		analysis = append(analysis, fmt.Sprintf("%s is cheaper by $%.0f per year on the loaded import/export profile.", req.CandidatePlan.Name, math.Abs(delta)))
	case "worse":
		analysis = append(analysis, fmt.Sprintf("%s is more expensive by $%.0f per year on the loaded import/export profile.", req.CandidatePlan.Name, delta))
	default:
		analysis = append(analysis, "The two plans are effectively tied on the loaded import/export profile.")
	}
	analysis = append(analysis, fmt.Sprintf("Across %.1f years, the difference is $%.0f.", horizon, delta*horizon))
	if batteryPayback > 0 {
		analysis = append(analysis, fmt.Sprintf("Battery payback from actual discharge value is %.1f years at current-plan rates.", batteryPayback))
	} else if req.PaybackYears > 0 {
		analysis = append(analysis, "Using the manually supplied battery payback period.")
	} else {
		analysis = append(analysis, "No battery discharge value was available, so a 10-year comparison horizon was used.")
	}
	if len(req.CandidatePlan.Unsupported) > 0 {
		analysis = append(analysis, "Imported plan has unsupported details: "+joinSentences(req.CandidatePlan.Unsupported))
	}

	return PlanComparison{
		Current:                     current,
		Candidate:                   candidate,
		AnnualDelta:                 round2(delta),
		HorizonYears:                round1(horizon),
		HorizonDelta:                round2(delta * horizon),
		Verdict:                     verdict,
		BatteryAnnualDischargeValue: round2(batteryAnnualValue),
		BatteryPaybackYears:         round1(batteryPayback),
		Analysis:                    analysis,
	}
}

func CalculatePlanCost(data []UsageRecord, plan Plan) PlanCostBreakdown {
	loc, _ := time.LoadLocation("Australia/Sydney")
	days := buildDaySlices(data, loc)
	nDays := len(days)
	if nDays == 0 {
		return PlanCostBreakdown{PlanName: plan.Name}
	}

	energy := 0.0
	feedIn := 0.0
	gridImport := 0.0
	solarExport := 0.0
	for _, r := range data {
		price := getPriceAt(plan, r.Timestamp)
		energy += r.GridImport * price
		feedIn += r.SolarExp * plan.FeedInTariff
		gridImport += r.GridImport
		solarExport += r.SolarExp
	}
	supply := float64(nDays) * plan.SupplyCharge
	factor := 365.0 / float64(nDays)
	return PlanCostBreakdown{
		PlanName:       plan.Name,
		AnnualCost:     round2((energy + supply - feedIn) * factor),
		AnnualEnergy:   round2(energy * factor),
		AnnualSupply:   round2(supply * factor),
		AnnualFeedIn:   round2(feedIn * factor),
		DaysSimulated:  nDays,
		GridImportKWh:  round2(gridImport * factor),
		SolarExportKWh: round2(solarExport * factor),
	}
}

func calculateBatteryDischargeValue(data []UsageRecord, plan Plan) float64 {
	loc, _ := time.LoadLocation("Australia/Sydney")
	days := buildDaySlices(data, loc)
	if len(days) == 0 {
		return 0
	}
	value := 0.0
	for _, r := range data {
		if r.BatteryDischarge <= 0 {
			continue
		}
		value += r.BatteryDischarge * getPriceAt(plan, r.Timestamp)
	}
	return value * 365.0 / float64(len(days))
}

func round2(v float64) float64 { return math.Round(v*100) / 100 }
func round1(v float64) float64 { return math.Round(v*10) / 10 }

func joinSentences(items []string) string {
	out := ""
	for i, item := range items {
		if i > 0 {
			out += "; "
		}
		out += item
	}
	return out
}
