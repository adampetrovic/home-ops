package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

type emePlanEnvelope struct {
	Data struct {
		PlanData emePlanData     `json:"planData"`
		PlanID   string          `json:"planId"`
		PCR      map[string]any  `json:"pcr"`
		Postcode json.RawMessage `json:"postcodes"`
	} `json:"data"`
}

type emePlanData struct {
	PlanName     string        `json:"planName"`
	PlanID       string        `json:"planId"`
	RetailerName string        `json:"retailerName"`
	TariffType   string        `json:"tariffType"`
	FuelType     string        `json:"fuelType"`
	Contract     []emeContract `json:"contract"`
}

type emeContract struct {
	PricingModel string            `json:"pricingModel"`
	FuelType     string            `json:"fuelType"`
	TariffPeriod []emeTariffPeriod `json:"tariffPeriod"`
	SolarFit     []emeSolarFit     `json:"solarFit"`
}

type emeTariffPeriod struct {
	Name              string            `json:"name"`
	StartDate         string            `json:"startDate"`
	EndDate           string            `json:"endDate"`
	DailySupplyCharge float64           `json:"dailySupplyCharge"`
	BlockRate         []emeBlockRate    `json:"blockRate"`
	TouBlock          []emeTOUBlock     `json:"touBlock"`
	DemandCharge      []emeDemandCharge `json:"demandCharge"`
}

type emeTOUBlock struct {
	Name            string         `json:"name"`
	Description     string         `json:"description"`
	TimeOfUsePeriod string         `json:"timeOfUsePeriod"`
	BlockRate       []emeBlockRate `json:"blockRate"`
	TimeOfUse       []emeTOU       `json:"timeOfUse"`
}

type emeTOU struct {
	Days      string `json:"days"`
	StartTime string `json:"startTime"`
	EndTime   string `json:"endTime"`
}

type emeBlockRate struct {
	UnitPrice   float64 `json:"unitPrice"`
	MeasureUnit string  `json:"measureUnit"`
}

type emeSolarFit struct {
	Rate              float64        `json:"rate"`
	DisplayName       string         `json:"displayName"`
	SingleTariffRates []emeBlockRate `json:"singleTariffRates"`
}

type emeDemandCharge struct {
	Name        string  `json:"name"`
	Rate        float64 `json:"rate"`
	StartTime   string  `json:"startTime"`
	EndTime     string  `json:"endTime"`
	Description string  `json:"description"`
}

func handleEMEPlan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	planID := strings.TrimSpace(r.URL.Query().Get("id"))
	if planID == "" {
		planID = strings.TrimSpace(r.URL.Query().Get("planId"))
	}
	if planID == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	postcode := strings.TrimSpace(r.URL.Query().Get("postcode"))
	if postcode == "" {
		postcode = "2213"
	}

	plan, err := fetchEnergyMadeEasyPlan(planID, postcode)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	jsonResp(w, map[string]any{"plan": plan})
}

func fetchEnergyMadeEasyPlan(planID, postcode string) (Plan, error) {
	resolvedPlanID, env, err := fetchEnergyMadeEasyPlanEnvelope(planID, postcode)
	if err != nil {
		return Plan{}, err
	}

	pd := env.Data.PlanData
	out := Plan{
		Name:     pd.PlanName,
		PlanID:   env.Data.PlanID,
		Retailer: pd.RetailerName,
	}
	if out.PlanID == "" {
		out.PlanID = resolvedPlanID
	}
	if out.Name == "" {
		out.Name = out.PlanID
	}

	contract := chooseElectricityContract(pd.Contract)
	out.FeedInTariff = extractFeedInTariff(contract, &out.Unsupported)

	supplySeen := false
	for _, period := range contract.TariffPeriod {
		months := monthsForPeriod(period.StartDate, period.EndDate)
		if period.DailySupplyCharge > 0 {
			supply := centsToDollars(period.DailySupplyCharge)
			if !supplySeen {
				out.SupplyCharge = supply
				supplySeen = true
			} else if abs(out.SupplyCharge-supply) > 0.0001 {
				out.Unsupported = append(out.Unsupported, "seasonal supply charges differ; using the first daily supply charge")
			}
		}
		if len(period.DemandCharge) > 0 {
			out.Unsupported = append(out.Unsupported, "demand charges present but not included in cost comparison")
		}
		if len(period.BlockRate) > 0 {
			if len(period.BlockRate) > 1 {
				out.Unsupported = append(out.Unsupported, "tiered single-rate usage charges present; using the first tier")
			}
			rate := centsToDollars(period.BlockRate[0].UnitPrice)
			out.Windows = append(out.Windows, TOUWindow{
				StartHour: 0, EndHour: 24, StartMinute: 0, EndMinute: 1440,
				Rate: rate, Label: labelOr(period.Name, "Usage"), Months: months,
			})
		}
		for _, block := range period.TouBlock {
			if len(block.BlockRate) == 0 {
				continue
			}
			if len(block.BlockRate) > 1 {
				out.Unsupported = append(out.Unsupported, "tiered TOU usage charges present; using the first tier")
			}
			rate := centsToDollars(block.BlockRate[0].UnitPrice)
			label := labelOr(block.Name, block.TimeOfUsePeriod)
			for _, tou := range block.TimeOfUse {
				start := parseHHMMStart(tou.StartTime)
				end := parseHHMMEnd(tou.EndTime)
				out.Windows = append(out.Windows, TOUWindow{
					StartHour:   start / 60,
					EndHour:     end / 60,
					StartMinute: start,
					EndMinute:   end,
					Rate:        rate,
					Label:       label,
					Months:      months,
					Days:        splitDays(tou.Days),
				})
			}
		}
	}

	if len(out.Windows) == 0 {
		out.Unsupported = append(out.Unsupported, "no usage windows could be imported")
	}
	out.Unsupported = uniqueStrings(out.Unsupported)
	return out, nil
}

type emeHTTPError struct {
	StatusCode int
	Body       string
}

func (e emeHTTPError) Error() string {
	if strings.TrimSpace(e.Body) == "" {
		return fmt.Sprintf("Energy Made Easy returned HTTP %d", e.StatusCode)
	}
	return fmt.Sprintf("Energy Made Easy returned HTTP %d: %s", e.StatusCode, strings.TrimSpace(e.Body))
}

func fetchEnergyMadeEasyPlanEnvelope(planID, postcode string) (string, emePlanEnvelope, error) {
	client := http.Client{Timeout: 25 * time.Second}
	candidates := emePlanIDCandidates(planID)
	var lastErr error

	for _, candidate := range candidates {
		env, err := getEnergyMadeEasyPlanEnvelope(client, candidate, postcode)
		if err == nil {
			return candidate, env, nil
		}
		lastErr = err
		if !isEnergyMadeEasyPlanNotFound(err) {
			return "", emePlanEnvelope{}, err
		}
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("plan %s not found", planID)
	}
	return "", emePlanEnvelope{}, fmt.Errorf("Energy Made Easy could not find plan %s for postcode %s", planID, postcode)
}

func getEnergyMadeEasyPlanEnvelope(client http.Client, planID, postcode string) (emePlanEnvelope, error) {
	u := fmt.Sprintf("https://api.energymadeeasy.gov.au/consumerplan/plan/%s?postcode=%s&withPrices=true", url.PathEscape(planID), url.QueryEscape(postcode))
	resp, err := client.Get(u)
	if err != nil {
		return emePlanEnvelope{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return emePlanEnvelope{}, emeHTTPError{StatusCode: resp.StatusCode, Body: string(body)}
	}

	var env emePlanEnvelope
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return emePlanEnvelope{}, err
	}
	pd := env.Data.PlanData
	if pd.PlanName == "" && len(pd.Contract) == 0 {
		return emePlanEnvelope{}, fmt.Errorf("plan %s not found", planID)
	}
	return env, nil
}

func isEnergyMadeEasyPlanNotFound(err error) bool {
	httpErr, ok := err.(emeHTTPError)
	if !ok {
		return strings.Contains(strings.ToLower(err.Error()), "not found")
	}
	return httpErr.StatusCode == http.StatusBadRequest && strings.Contains(strings.ToLower(httpErr.Body), "cannot find plans")
}

func emePlanIDCandidates(planID string) []string {
	planID = strings.TrimSpace(planID)
	if planID == "" {
		return nil
	}
	out := []string{planID}
	if lastCharIsDigit(planID) {
		return out
	}
	for i := 1; i <= 50; i++ {
		out = append(out, fmt.Sprintf("%s%d", planID, i))
	}
	return out
}

func lastCharIsDigit(s string) bool {
	if s == "" {
		return false
	}
	last := s[len(s)-1]
	return last >= '0' && last <= '9'
}

func chooseElectricityContract(contracts []emeContract) emeContract {
	for _, c := range contracts {
		if c.FuelType == "" || strings.EqualFold(c.FuelType, "E") {
			return c
		}
	}
	if len(contracts) > 0 {
		return contracts[0]
	}
	return emeContract{}
}

func extractFeedInTariff(contract emeContract, warnings *[]string) float64 {
	if len(contract.SolarFit) == 0 {
		return 0
	}
	fit := contract.SolarFit[0]
	if len(contract.SolarFit) > 1 {
		*warnings = append(*warnings, "multiple feed-in tariffs present; using the first")
	}
	if len(fit.SingleTariffRates) > 0 {
		if len(fit.SingleTariffRates) > 1 {
			*warnings = append(*warnings, "tiered feed-in tariff present; using the first tier")
		}
		return centsToDollars(fit.SingleTariffRates[0].UnitPrice)
	}
	return centsToDollars(fit.Rate)
}

func centsToDollars(v float64) float64 { return v / 100.0 }

func labelOr(values ...string) string {
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v != "" {
			return v
		}
	}
	return "Usage"
}

func parseHHMMStart(s string) int {
	if len(s) < 3 {
		return 0
	}
	if len(s) == 3 {
		s = "0" + s
	}
	h, _ := strconv.Atoi(s[:2])
	m, _ := strconv.Atoi(s[2:4])
	return clampMinute(h*60 + m)
}

func parseHHMMEnd(s string) int {
	if strings.TrimSpace(s) == "" {
		return 1440
	}
	end := parseHHMMStart(s) + 1 // EME end times are inclusive, e.g. 2059
	if strings.HasSuffix(s, "00") {
		// Some plans use exact boundary end times. Treat 2400 specially; otherwise
		// still prefer exclusive end semantics by leaving the boundary unchanged.
		if s == "2400" {
			return 1440
		}
	}
	if end > 1440 {
		end = 1440
	}
	return end
}

func clampMinute(v int) int {
	if v < 0 {
		return 0
	}
	if v > 1440 {
		return 1440
	}
	return v
}

func splitDays(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, "|")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.ToUpper(strings.TrimSpace(p))
		if p != "" && p != "PUBLIC_HOLIDAYS" {
			out = append(out, p)
		}
	}
	return out
}

func monthsForPeriod(startDate, endDate string) []int {
	if startDate == "" || endDate == "" {
		return nil
	}
	start, err1 := time.Parse("2006-01-02", startDate)
	end, err2 := time.Parse("2006-01-02", endDate)
	if err1 != nil || err2 != nil {
		return nil
	}
	startMonth := int(start.Month())
	endMonth := int(end.Month())
	var months []int
	m := startMonth
	for {
		months = append(months, m)
		if m == endMonth {
			break
		}
		m++
		if m == 13 {
			m = 1
		}
		if len(months) >= 12 {
			break
		}
	}
	sort.Ints(months)
	return months
}

func uniqueStrings(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
