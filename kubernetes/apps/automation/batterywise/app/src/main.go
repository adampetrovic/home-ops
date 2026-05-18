package main

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var store *Store

func main() {
	port := "8080"
	if p := os.Getenv("PORT"); p != "" {
		port = p
	}

	configDir := os.Getenv("CONFIG_DIR")
	if configDir == "" {
		configDir = "./config"
	}

	var err error
	store, err = NewStore(configDir)
	if err != nil {
		log.Fatalf("Failed to initialise database: %v", err)
	}
	defer store.Close()

	mux := http.NewServeMux()

	// Data endpoints
	mux.HandleFunc("/api/upload", handleUpload)
	mux.HandleFunc("/api/data/status", handleDataStatus)
	mux.HandleFunc("/api/sample-csv", handleSampleCSV)
	mux.HandleFunc("/api/generate-sample", handleGenerateSample)
	mux.HandleFunc("/api/influx/import", handleInfluxImport)
	mux.HandleFunc("/api/eme/plan", handleEMEPlan)
	mux.HandleFunc("/api/compare-plan", handleComparePlan)

	// Simulation
	mux.HandleFunc("/api/simulate", handleSimulate)

	// Scenario CRUD
	mux.HandleFunc("/api/scenarios", handleScenarios)
	mux.HandleFunc("/api/scenarios/", handleScenarioByID) // /api/scenarios/{id}

	// Static files
	webDir := filepath.Join(".", "web")
	mux.Handle("/", http.FileServer(http.Dir(webDir)))

	log.Printf("BatteryWise starting on http://localhost:%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

// ---------------------------------------------------------------------------
// Data endpoints
// ---------------------------------------------------------------------------

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	r.ParseMultipartForm(50 << 20) // 50 MB
	file, _, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "No file: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	records, err := parseCSV(file)
	if err != nil {
		http.Error(w, "CSV parse error: "+err.Error(), http.StatusBadRequest)
		return
	}

	if err := store.ReplaceUsageData(records); err != nil {
		http.Error(w, "Storage error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	resp := map[string]interface{}{
		"records": len(records),
		"start":   records[0].Timestamp,
		"end":     records[len(records)-1].Timestamp,
	}
	jsonResp(w, resp)
}

func handleDataStatus(w http.ResponseWriter, r *http.Request) {
	loaded, count, start, end, days := store.UsageDataStatus()
	resp := map[string]interface{}{
		"loaded":  loaded,
		"records": count,
	}
	if loaded {
		resp["start"] = start
		resp["end"] = end
		resp["days"] = days
	}
	jsonResp(w, resp)
}

func handleSampleCSV(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/csv")
	w.Header().Set("Content-Disposition", "attachment; filename=batterywise_template.csv")
	w.Write([]byte(`datetime,grid_import_kwh,solar_generation_kwh,solar_export_kwh
2025-01-01 00:00,0.50,0.00,0.00
2025-01-01 00:15,0.48,0.00,0.00
2025-01-01 00:30,0.45,0.00,0.00
2025-01-01 00:45,0.52,0.00,0.00
2025-01-01 01:00,0.40,0.00,0.00
`))
}

func handleGenerateSample(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	records := generateSampleData(365)
	if err := store.ReplaceUsageData(records); err != nil {
		http.Error(w, "Storage error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	resp := map[string]interface{}{
		"records": len(records),
		"start":   records[0].Timestamp,
		"end":     records[len(records)-1].Timestamp,
		"days":    365,
		"message": "Generated 365 days of synthetic usage data",
	}
	jsonResp(w, resp)
}

// ---------------------------------------------------------------------------
// Simulation
// ---------------------------------------------------------------------------

func handleSimulate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	var req SimRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}

	data, err := store.LoadUsageData()
	if err != nil || len(data) == 0 {
		http.Error(w, "No usage data loaded. Upload a CSV or generate sample data first.", http.StatusBadRequest)
		return
	}

	result := RunSimulation(data, req.Scenario)

	// Persist scenario + result if it has a name
	if req.Scenario.Name != "" {
		scID, err := store.SaveScenario(req.Scenario)
		if err == nil {
			store.SaveResult(scID, result)
		}
	}

	jsonResp(w, result)
}

// ---------------------------------------------------------------------------
// Scenario CRUD
// ---------------------------------------------------------------------------

func handleScenarios(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		list, err := store.ListScenarios()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if list == nil {
			list = []ScenarioRecord{}
		}
		// Attach latest result to each
		type scenarioWithResult struct {
			ScenarioRecord
			Result *SimResult `json:"result,omitempty"`
		}
		var out []scenarioWithResult
		for _, sc := range list {
			sr := scenarioWithResult{ScenarioRecord: sc}
			if res, err := store.GetResult(sc.ID); err == nil {
				sr.Result = &res
			}
			out = append(out, sr)
		}
		jsonResp(w, out)

	case http.MethodPost:
		var sc Scenario
		if err := json.NewDecoder(r.Body).Decode(&sc); err != nil {
			http.Error(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
			return
		}
		id, err := store.SaveScenario(sc)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonResp(w, map[string]interface{}{"id": id, "name": sc.Name})

	default:
		http.Error(w, "GET or POST", http.StatusMethodNotAllowed)
	}
}

func handleScenarioByID(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/api/scenarios/")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid scenario ID", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodGet:
		sc, err := store.GetScenario(id)
		if err != nil {
			http.Error(w, "Not found", http.StatusNotFound)
			return
		}
		jsonResp(w, sc)

	case http.MethodDelete:
		if err := store.DeleteScenario(id); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonResp(w, map[string]string{"status": "deleted"})

	default:
		http.Error(w, "GET or DELETE", http.StatusMethodNotAllowed)
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func jsonResp(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// ---------------------------------------------------------------------------
// CSV parser
// ---------------------------------------------------------------------------

func parseCSV(r io.Reader) ([]UsageRecord, error) {
	reader := csv.NewReader(r)
	reader.TrimLeadingSpace = true

	headers, err := reader.Read()
	if err != nil {
		return nil, fmt.Errorf("reading headers: %w", err)
	}

	colMap := map[string]int{}
	for i, h := range headers {
		colMap[strings.ToLower(strings.TrimSpace(h))] = i
	}

	tsCol, impCol, genCol, expCol, battDisCol := -1, -1, -1, -1, -1
	for name, idx := range colMap {
		switch {
		case strings.Contains(name, "datetime") || strings.Contains(name, "timestamp") || name == "time":
			tsCol = idx
		case strings.Contains(name, "battery") && strings.Contains(name, "discharge"):
			battDisCol = idx
		case strings.Contains(name, "import") || strings.Contains(name, "grid_import"):
			impCol = idx
		case strings.Contains(name, "generation") || strings.Contains(name, "solar_gen"):
			genCol = idx
		case strings.Contains(name, "export") || strings.Contains(name, "solar_exp"):
			expCol = idx
		}
	}

	if tsCol < 0 {
		return nil, fmt.Errorf("no datetime/timestamp column found")
	}
	if impCol < 0 {
		return nil, fmt.Errorf("no grid import column found")
	}

	formats := []string{
		"2006-01-02 15:04:05",
		"2006-01-02 15:04",
		"2006-01-02T15:04:05Z07:00",
		"2006-01-02T15:04:05",
		"2006-01-02T15:04Z07:00",
		"02/01/2006 15:04",
		"1/2/2006 15:04",
	}

	var records []UsageRecord
	lineNum := 1
	for {
		row, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNum+1, err)
		}
		lineNum++

		tsStr := strings.TrimSpace(row[tsCol])
		var ts time.Time
		parsed := false
		for _, f := range formats {
			if t, err := time.Parse(f, tsStr); err == nil {
				ts = t
				parsed = true
				break
			}
		}
		if !parsed {
			return nil, fmt.Errorf("line %d: cannot parse timestamp '%s'", lineNum, tsStr)
		}

		imp, _ := strconv.ParseFloat(strings.TrimSpace(row[impCol]), 64)
		gen, exp, battDis := 0.0, 0.0, 0.0
		if genCol >= 0 && genCol < len(row) {
			gen, _ = strconv.ParseFloat(strings.TrimSpace(row[genCol]), 64)
		}
		if expCol >= 0 && expCol < len(row) {
			exp, _ = strconv.ParseFloat(strings.TrimSpace(row[expCol]), 64)
		}
		if battDisCol >= 0 && battDisCol < len(row) {
			battDis, _ = strconv.ParseFloat(strings.TrimSpace(row[battDisCol]), 64)
		}

		records = append(records, UsageRecord{
			Timestamp:        ts,
			GridImport:       imp,
			SolarGen:         gen,
			SolarExp:         exp,
			BatteryDischarge: battDis,
		})
	}

	if len(records) == 0 {
		return nil, fmt.Errorf("no data rows found")
	}
	return records, nil
}

// ---------------------------------------------------------------------------
// Sample data generator
// ---------------------------------------------------------------------------

func generateSampleData(days int) []UsageRecord {
	loc, _ := time.LoadLocation("Australia/Sydney")
	start := time.Date(2025, 1, 1, 0, 0, 0, 0, loc)
	intervalsPerDay := 96
	var records []UsageRecord

	rng := rand.New(rand.NewSource(42))

	for d := 0; d < days; d++ {
		dayStart := start.AddDate(0, 0, d)
		month := dayStart.Month()
		dayOfYear := dayStart.YearDay()

		seasonAngle := 2 * math.Pi * float64(dayOfYear-1) / 365.0
		solarFactor := 1.2 + 0.6*math.Cos(seasonAngle+math.Pi)

		isWeekend := dayStart.Weekday() == time.Saturday || dayStart.Weekday() == time.Sunday
		dailyVar := 0.85 + rng.Float64()*0.3
		isHotDay := (month >= 11 || month <= 3) && rng.Float64() < 0.4
		isColdDay := (month >= 6 && month <= 8) && rng.Float64() < 0.3

		evChargeToday := rng.Float64() < 0.6
		evKWhNeeded := 5.0 + rng.Float64()*25.0

		for i := 0; i < intervalsPerDay; i++ {
			ts := dayStart.Add(time.Duration(i*15) * time.Minute)
			hour := float64(i) / 4.0

			solarPeak := 10.0 * solarFactor
			solar := 0.0
			if hour >= 5.5 && hour <= 19.5 {
				solarHour := (hour - 5.5) / (19.5 - 5.5)
				solar = solarPeak * math.Sin(math.Pi*solarHour)
				cloudFactor := 0.3 + rng.Float64()*0.7
				if rng.Float64() < 0.15 {
					cloudFactor = 0.05 + rng.Float64()*0.2
				}
				solar *= cloudFactor * 0.25
				solar = math.Max(0, solar)
			}

			baseKW := 0.8
			var load float64

			switch {
			case hour < 5:
				load = baseKW * (0.7 + rng.Float64()*0.3)
			case hour < 6:
				load = baseKW * (0.9 + rng.Float64()*0.3)
			case hour < 9:
				morningFactor := 2.5 + rng.Float64()*1.5
				if isWeekend {
					morningFactor *= 0.7
				}
				load = baseKW * morningFactor
			case hour < 15:
				load = baseKW * (0.8 + rng.Float64()*0.6)
				if isWeekend {
					load *= 1.5
				}
			case hour < 21:
				eveningFactor := 3.0 + rng.Float64()*2.5
				if isHotDay {
					eveningFactor += 2.0 + rng.Float64()*3.0
				}
				if isColdDay {
					eveningFactor += 1.0 + rng.Float64()*1.0
				}
				load = baseKW * eveningFactor
			default:
				load = baseKW * (1.2 + rng.Float64()*0.8)
			}

			load *= dailyVar * 0.25

			if isHotDay && hour >= 11 && hour < 22 {
				acKW := 1.5 + rng.Float64()*2.5
				load += acKW * 0.25
			}

			if evChargeToday && hour >= 0 && hour < 6 && evKWhNeeded > 0 {
				evKW := 7.0 + rng.Float64()*4.0
				evThisInterval := math.Min(evKW*0.25, evKWhNeeded)
				load += evThisInterval
				evKWhNeeded -= evThisInterval
			}

			if (hour >= 4 && hour < 7) || (hour >= 12 && hour < 15) {
				load += 1.2 * 0.25
			}

			netLoad := load - solar
			gridImport := math.Max(0, netLoad)
			solarExport := math.Max(0, -netLoad)

			records = append(records, UsageRecord{
				Timestamp:  ts,
				GridImport: math.Round(gridImport*1000) / 1000,
				SolarGen:   math.Round(solar*1000) / 1000,
				SolarExp:   math.Round(solarExport*1000) / 1000,
			})
		}
	}
	return records
}
