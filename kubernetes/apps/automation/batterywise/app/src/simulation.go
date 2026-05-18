package main

import (
	"math"
	"strings"
	"time"
)

// UsageRecord represents a single interval of energy data
type UsageRecord struct {
	Timestamp        time.Time `json:"timestamp"`
	GridImport       float64   `json:"grid_import_kwh"`
	SolarGen         float64   `json:"solar_generation_kwh"`
	SolarExp         float64   `json:"solar_export_kwh"`
	BatteryDischarge float64   `json:"battery_discharge_kwh,omitempty"`
}

// TOUWindow defines a rate for a time window
type TOUWindow struct {
	StartHour   int      `json:"start_hour"`             // 0-23
	EndHour     int      `json:"end_hour"`               // 1-24 (exclusive)
	StartMinute int      `json:"start_minute,omitempty"` // 0-1439; overrides StartHour when set
	EndMinute   int      `json:"end_minute,omitempty"`   // 1-1440; overrides EndHour when set
	Rate        float64  `json:"rate"`                   // $/kWh
	Label       string   `json:"label"`
	Months      []int    `json:"months,omitempty"` // 1-12; empty means all months
	Days        []string `json:"days,omitempty"`   // SUN|MON|...; empty means all days
}

// Plan defines a TOU electricity plan
type Plan struct {
	Name         string      `json:"name"`
	PlanID       string      `json:"plan_id,omitempty"`
	Retailer     string      `json:"retailer,omitempty"`
	Windows      []TOUWindow `json:"windows"`
	SupplyCharge float64     `json:"supply_charge"`  // $/day
	FeedInTariff float64     `json:"feed_in_tariff"` // $/kWh
	Unsupported  []string    `json:"unsupported,omitempty"`
}

// BatteryConfig defines battery hardware parameters
type BatteryConfig struct {
	CapacityKWh    float64 `json:"capacity_kwh"`
	UsablePercent  float64 `json:"usable_percent"` // 0-100
	RoundTripEff   float64 `json:"round_trip_eff"` // 0-100
	MaxChargeKW    float64 `json:"max_charge_kw"`
	MaxDischargeKW float64 `json:"max_discharge_kw"`
	CostDollars    float64 `json:"cost_dollars"`
}

func (b BatteryConfig) UsableKWh() float64 {
	return b.CapacityKWh * b.UsablePercent / 100.0
}

func (b BatteryConfig) Efficiency() float64 {
	return b.RoundTripEff / 100.0
}

// StrategyRule defines a single battery dispatch rule
type StrategyRule struct {
	Type      string  `json:"type"`       // "time", "threshold", "solar"
	Action    string  `json:"action"`     // "charge", "discharge", "idle"
	StartHour int     `json:"start_hour"` // for time rules
	EndHour   int     `json:"end_hour"`   // for time rules
	SOCTarget float64 `json:"soc_target"` // target SOC % for charge (0-100)
	SOCFloor  float64 `json:"soc_floor"`  // min SOC % for discharge (0-100)
	Threshold float64 `json:"threshold"`  // price threshold for threshold rules
}

// Strategy combines rules for battery dispatch
type Strategy struct {
	Name               string         `json:"name"`
	Rules              []StrategyRule `json:"rules"`
	AlwaysCaptureSolar bool           `json:"always_capture_solar"`
}

// Scenario is a complete simulation configuration
type Scenario struct {
	Name     string        `json:"name"`
	Plan     Plan          `json:"plan"`
	Battery  BatteryConfig `json:"battery"`
	Strategy Strategy      `json:"strategy"`
}

// SimRequest is the API request for simulation
type SimRequest struct {
	Scenario Scenario `json:"scenario"`
}

// HourlyProfile contains averaged data for one hour
type HourlyProfile struct {
	Hour         int     `json:"hour"`
	AvgSOC       float64 `json:"avg_soc"`
	GridCharge   float64 `json:"grid_charge"`
	SolarCapture float64 `json:"solar_capture"`
	Discharge    float64 `json:"discharge"`
	GridImport   float64 `json:"grid_import"`
	GridExport   float64 `json:"grid_export"`
	Cost         float64 `json:"cost"`
	Price        float64 `json:"price"`
}

// SimResult is returned from a simulation run
type SimResult struct {
	BaselineAnnual  float64         `json:"baseline_annual"`
	OptimizedAnnual float64         `json:"optimized_annual"`
	AnnualSavings   float64         `json:"annual_savings"`
	PaybackYears    float64         `json:"payback_years"`
	AnnualCycles    float64         `json:"annual_cycles"`
	DaysSimulated   int             `json:"days_simulated"`
	TotalGridCharge float64         `json:"total_grid_charge"`
	TotalSolarCap   float64         `json:"total_solar_capture"`
	TotalDischarge  float64         `json:"total_discharge"`
	HourlyProfile   []HourlyProfile `json:"hourly_profile"`
	MonthlyCosts    []float64       `json:"monthly_costs"`
	MonthlyBaseline []float64       `json:"monthly_baseline"`
}

// getPriceForHour returns the TOU rate for a given hour. It is retained for
// callers that only need a representative hourly price.
func getPriceForHour(plan Plan, hour int) float64 {
	loc := sydneyLocation()
	return getPriceAt(plan, time.Date(2026, time.January, 1, hour, 0, 0, 0, loc))
}

func windowStartEndMinutes(w TOUWindow) (int, int) {
	start := w.StartMinute
	if start == 0 && w.StartHour > 0 {
		start = w.StartHour * 60
	}
	end := w.EndMinute
	if end == 0 {
		if w.EndHour > 0 {
			end = w.EndHour * 60
		} else {
			end = 24 * 60
		}
	}
	if start < 0 {
		start = 0
	}
	if start > 1439 {
		start = 1439
	}
	if end < 1 {
		end = 1
	}
	if end > 1440 {
		end = 1440
	}
	return start, end
}

func containsMonth(months []int, m int) bool {
	if len(months) == 0 {
		return true
	}
	for _, x := range months {
		if x == m {
			return true
		}
	}
	return false
}

func dayCode(t time.Time) string {
	switch t.Weekday() {
	case time.Sunday:
		return "SUN"
	case time.Monday:
		return "MON"
	case time.Tuesday:
		return "TUE"
	case time.Wednesday:
		return "WED"
	case time.Thursday:
		return "THU"
	case time.Friday:
		return "FRI"
	default:
		return "SAT"
	}
}

func containsDay(days []string, d string) bool {
	if len(days) == 0 {
		return true
	}
	for _, x := range days {
		if strings.EqualFold(strings.TrimSpace(x), d) {
			return true
		}
	}
	return false
}

// getPriceAt returns the TOU rate for a timestamp, including optional month
// and day constraints imported from Energy Made Easy.
func getPriceAt(plan Plan, ts time.Time) float64 {
	loc := sydneyLocation()
	lt := ts.In(loc)
	minute := lt.Hour()*60 + lt.Minute()
	month := int(lt.Month())
	day := dayCode(lt)

	for _, w := range plan.Windows {
		if !containsMonth(w.Months, month) || !containsDay(w.Days, day) {
			continue
		}

		start, end := windowStartEndMinutes(w)
		if start <= end {
			if minute >= start && minute < end {
				return w.Rate
			}
		} else {
			// wraps around midnight
			if minute >= start || minute < end {
				return w.Rate
			}
		}
	}
	return 0.30 // fallback
}

// daySlice identifies contiguous intervals for one calendar day
type daySlice struct {
	start int
	end   int
	date  time.Time
}

func buildDaySlices(data []UsageRecord, loc *time.Location) []daySlice {
	if len(data) == 0 {
		return nil
	}
	var slices []daySlice
	currentDate := localMidnight(data[0].Timestamp, loc)
	startIdx := 0

	for i, r := range data {
		d := localMidnight(r.Timestamp, loc)
		if !d.Equal(currentDate) {
			slices = append(slices, daySlice{start: startIdx, end: i, date: currentDate})
			currentDate = d
			startIdx = i
		}
	}
	slices = append(slices, daySlice{start: startIdx, end: len(data), date: currentDate})
	return slices
}

func localMidnight(t time.Time, loc *time.Location) time.Time {
	lt := t.In(loc)
	return time.Date(lt.Year(), lt.Month(), lt.Day(), 0, 0, 0, 0, loc)
}

// RunSimulation executes the battery simulation
func RunSimulation(data []UsageRecord, scenario Scenario) SimResult {
	if len(data) == 0 {
		return SimResult{}
	}

	loc := sydneyLocation()
	days := buildDaySlices(data, loc)
	nDays := len(days)
	if nDays == 0 {
		return SimResult{}
	}

	battery := scenario.Battery
	plan := scenario.Plan
	strategy := scenario.Strategy

	usableCap := battery.UsableKWh()
	eff := battery.Efficiency()

	// Detect interval duration (minutes)
	intervalMin := 15.0
	if len(data) > 1 {
		diff := data[1].Timestamp.Sub(data[0].Timestamp).Minutes()
		if diff > 0 {
			intervalMin = diff
		}
	}
	intervalHours := intervalMin / 60.0
	maxChargePerInterval := battery.MaxChargeKW * intervalHours
	maxDischargePerInterval := battery.MaxDischargeKW * intervalHours

	// Hourly accumulators
	hourlySOC := make([]float64, 24)
	hourlyCount := make([]float64, 24)
	hourlyCharge := make([]float64, 24)
	hourlySolar := make([]float64, 24)
	hourlyDischarge := make([]float64, 24)
	hourlyImport := make([]float64, 24)
	hourlyExport := make([]float64, 24)
	hourlyCost := make([]float64, 24)

	// Monthly accumulators
	monthlyCost := make([]float64, 12)
	monthlyBaseline := make([]float64, 12)
	monthlyDays := make([]float64, 12)

	// Baseline cost (no battery)
	baselineCost := 0.0
	for _, r := range data {
		p := getPriceAt(plan, r.Timestamp)
		baselineCost += r.GridImport*p - r.SolarExp*plan.FeedInTariff
		m := r.Timestamp.In(loc).Month() - 1
		monthlyBaseline[m] += r.GridImport*p - r.SolarExp*plan.FeedInTariff
	}
	baselineCost += float64(nDays) * plan.SupplyCharge
	for _, ds := range days {
		m := ds.date.In(loc).Month() - 1
		monthlyDays[m]++
		monthlyBaseline[m] += plan.SupplyCharge
	}

	// Battery simulation
	soc := 0.0
	totalCost := 0.0
	totalDischarged := 0.0
	totalGridCharge := 0.0
	totalSolarCap := 0.0

	for _, r := range data {
		h := r.Timestamp.In(loc).Hour()
		m := r.Timestamp.In(loc).Month() - 1
		p := getPriceAt(plan, r.Timestamp)

		ia := r.GridImport // grid import this interval
		ea := r.SolarExp   // solar export this interval
		rem := maxChargePerInterval

		// Step 1: Solar capture (if enabled)
		solarCaptured := 0.0
		if strategy.AlwaysCaptureSolar && ea > 0 && soc < usableCap && rem > 0 {
			sc := math.Min(ea, math.Min(rem, usableCap-soc))
			soc += sc
			ea -= sc
			rem -= sc
			solarCaptured = sc
			totalSolarCap += sc
		}

		// Step 2: Evaluate strategy rules (first match wins)
		action := ""
		socTarget := 100.0
		socFloor := 0.0
		matched := false

		for _, rule := range strategy.Rules {
			if rule.Type == "solar" {
				continue // handled above
			}

			if rule.Type == "time" {
				inWindow := false
				if rule.StartHour <= rule.EndHour {
					inWindow = h >= rule.StartHour && h < rule.EndHour
				} else {
					inWindow = h >= rule.StartHour || h < rule.EndHour
				}
				if inWindow {
					action = rule.Action
					socTarget = rule.SOCTarget
					socFloor = rule.SOCFloor
					matched = true
					break
				}
			}

			if rule.Type == "threshold" {
				if rule.Action == "charge" && p <= rule.Threshold {
					action = "charge"
					socTarget = rule.SOCTarget
					if socTarget == 0 {
						socTarget = 100
					}
					matched = true
					break
				}
				if rule.Action == "discharge" && p >= rule.Threshold {
					action = "discharge"
					socFloor = rule.SOCFloor
					matched = true
					break
				}
			}
		}

		// If no rule matched, check remaining threshold rules
		if !matched {
			for _, rule := range strategy.Rules {
				if rule.Type == "threshold" {
					if rule.Action == "charge" && p <= rule.Threshold {
						action = "charge"
						socTarget = rule.SOCTarget
						if socTarget == 0 {
							socTarget = 100
						}
						break
					}
					if rule.Action == "discharge" && p >= rule.Threshold {
						action = "discharge"
						socFloor = rule.SOCFloor
						break
					}
				}
			}
		}

		// Step 3: Execute action
		gridCharged := 0.0
		discharged := 0.0

		targetKWh := usableCap * socTarget / 100.0
		floorKWh := usableCap * socFloor / 100.0

		switch action {
		case "charge":
			if soc < targetKWh && rem > 0 {
				gc := math.Min(rem, targetKWh-soc)
				gc = math.Min(gc, usableCap-soc)
				if gc > 0 {
					soc += gc
					ia += gc
					rem -= gc
					gridCharged = gc
					totalGridCharge += gc
				}
			}
		case "discharge":
			if soc > floorKWh && ia > 0 {
				maxDis := math.Min(ia, maxDischargePerInterval*eff)
				maxDis = math.Min(maxDis, (soc-floorKWh)*eff)
				if maxDis > 0 {
					soc -= maxDis / eff
					ia -= maxDis
					discharged = maxDis
					totalDischarged += maxDis
				}
			}
		}

		intervalCost := ia*p - ea*plan.FeedInTariff
		totalCost += intervalCost
		monthlyCost[m] += intervalCost

		// Accumulate hourly stats
		hourlySOC[h] += soc
		hourlyCount[h]++
		hourlyCharge[h] += gridCharged
		hourlySolar[h] += solarCaptured
		hourlyDischarge[h] += discharged
		hourlyImport[h] += ia
		hourlyExport[h] += ea
		hourlyCost[h] += intervalCost
	}

	totalCost += float64(nDays) * plan.SupplyCharge
	for m := 0; m < 12; m++ {
		monthlyCost[m] += monthlyDays[m] * plan.SupplyCharge
	}

	// Annualize
	annFactor := 365.0 / float64(nDays)

	// Build hourly profile
	hourly := make([]HourlyProfile, 24)
	for h := 0; h < 24; h++ {
		cnt := hourlyCount[h]
		if cnt == 0 {
			cnt = 1
		}
		hourly[h] = HourlyProfile{
			Hour:         h,
			AvgSOC:       hourlySOC[h] / cnt,
			GridCharge:   hourlyCharge[h] * annFactor,
			SolarCapture: hourlySolar[h] * annFactor,
			Discharge:    hourlyDischarge[h] * annFactor,
			GridImport:   hourlyImport[h] * annFactor,
			GridExport:   hourlyExport[h] * annFactor,
			Cost:         hourlyCost[h] * annFactor,
			Price:        getPriceForHour(plan, h),
		}
	}

	// Annualize monthly
	annMonthly := make([]float64, 12)
	annBaseline := make([]float64, 12)
	for m := 0; m < 12; m++ {
		if monthlyDays[m] > 0 {
			daysInMonth := []int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[m]
			factor := float64(daysInMonth) / monthlyDays[m]
			annMonthly[m] = monthlyCost[m] * factor
			annBaseline[m] = monthlyBaseline[m] * factor
		}
	}

	annualBase := baselineCost * annFactor
	annualOpt := totalCost * annFactor
	annualSave := annualBase - annualOpt
	payback := 999.0
	if annualSave > 0 {
		payback = battery.CostDollars / annualSave
	}
	cycles := totalDischarged * annFactor / usableCap

	return SimResult{
		BaselineAnnual:  math.Round(annualBase*100) / 100,
		OptimizedAnnual: math.Round(annualOpt*100) / 100,
		AnnualSavings:   math.Round(annualSave*100) / 100,
		PaybackYears:    math.Round(payback*10) / 10,
		AnnualCycles:    math.Round(cycles),
		DaysSimulated:   nDays,
		TotalGridCharge: math.Round(totalGridCharge * annFactor),
		TotalSolarCap:   math.Round(totalSolarCap * annFactor),
		TotalDischarge:  math.Round(totalDischarged * annFactor),
		HourlyProfile:   hourly,
		MonthlyCosts:    annMonthly,
		MonthlyBaseline: annBaseline,
	}
}
