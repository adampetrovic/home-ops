package main

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type InfluxImportRequest struct {
	Start  string `json:"start"`
	Stop   string `json:"stop"`
	Bucket string `json:"bucket"`
	Every  string `json:"every"`
}

func handleInfluxImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req InfluxImportRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && err != io.EOF {
		http.Error(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Start == "" {
		req.Start = "2026-04-09T00:00:00Z"
	}
	if req.Bucket == "" {
		req.Bucket = firstNonEmpty(os.Getenv("SIGENERGY_INFLUX_BUCKET"), os.Getenv("INFLUXDB_BUCKET"), "sigenergy")
	}
	if req.Every == "" {
		req.Every = "1h"
	}

	records, err := importSigenergyFromInflux(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if len(records) == 0 {
		http.Error(w, "InfluxDB query returned no records", http.StatusBadRequest)
		return
	}
	if err := store.ReplaceUsageData(records); err != nil {
		http.Error(w, "Storage error: "+err.Error(), http.StatusInternalServerError)
		return
	}

	resp := map[string]any{
		"records": len(records),
		"start":   records[0].Timestamp,
		"end":     records[len(records)-1].Timestamp,
		"days":    int(records[len(records)-1].Timestamp.Sub(records[0].Timestamp).Hours()/24) + 1,
		"message": "Imported Sigenergy usage from InfluxDB",
	}
	jsonResp(w, resp)
}

func importSigenergyFromInflux(req InfluxImportRequest) ([]UsageRecord, error) {
	influxURL := strings.TrimRight(os.Getenv("INFLUXDB_URL"), "/")
	org := os.Getenv("INFLUXDB_ORG")
	token := os.Getenv("INFLUXDB_TOKEN")
	if influxURL == "" || org == "" || token == "" {
		return nil, fmt.Errorf("INFLUXDB_URL, INFLUXDB_ORG and INFLUXDB_TOKEN must be set")
	}
	start := req.Start
	if !strings.HasPrefix(start, "-") && !strings.HasPrefix(start, "time(") {
		if _, err := time.Parse(time.RFC3339, start); err != nil {
			if t, err2 := time.Parse("2006-01-02", start); err2 == nil {
				start = t.Format(time.RFC3339)
			} else {
				return nil, fmt.Errorf("invalid start time %q", req.Start)
			}
		}
	}
	stopClause := ""
	if req.Stop != "" {
		stop := req.Stop
		if _, err := time.Parse(time.RFC3339, stop); err != nil {
			if t, err2 := time.Parse("2006-01-02", stop); err2 == nil {
				stop = t.Format(time.RFC3339)
			} else {
				return nil, fmt.Errorf("invalid stop time %q", req.Stop)
			}
		}
		stopClause = fmt.Sprintf(", stop: time(v: %q)", stop)
	}

	flux := fmt.Sprintf(`from(bucket: %q)
  |> range(start: time(v: %q)%s)
  |> filter(fn: (r) => r._measurement == "kWh" and r._field == "value" and (
    r.entity_id == "sigen_0_si_total_imported_energy" or
    r.entity_id == "sigen_0_si_total_exported_energy" or
    r.entity_id == "sigen_0_si_total_third_party_pv_generation" or
    r.entity_id == "sigen_0_si_total_discharged_energy"
  ))
  |> aggregateWindow(every: %s, fn: last, createEmpty: false, timeSrc: "_start")
  |> difference(nonNegative: true)
  |> pivot(rowKey: ["_time"], columnKey: ["entity_id"], valueColumn: "_value")
  |> keep(columns: ["_time", "sigen_0_si_total_imported_energy", "sigen_0_si_total_exported_energy", "sigen_0_si_total_third_party_pv_generation", "sigen_0_si_total_discharged_energy"])
`, req.Bucket, start, stopClause, req.Every)

	apiURL := fmt.Sprintf("%s/api/v2/query?org=%s", influxURL, org)
	hreq, err := http.NewRequest(http.MethodPost, apiURL, bytes.NewBufferString(flux))
	if err != nil {
		return nil, err
	}
	hreq.Header.Set("Authorization", "Token "+token)
	hreq.Header.Set("Accept", "application/csv")
	hreq.Header.Set("Content-Type", "application/vnd.flux")

	client := http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(hreq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("InfluxDB returned HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return parseInfluxCSV(body)
}

func parseInfluxCSV(body []byte) ([]UsageRecord, error) {
	r := csv.NewReader(bytes.NewReader(body))
	r.FieldsPerRecord = -1
	headers, err := r.Read()
	if err != nil {
		return nil, err
	}
	idx := map[string]int{}
	for i, h := range headers {
		idx[h] = i
	}
	timeIdx, ok := idx["_time"]
	if !ok {
		return nil, fmt.Errorf("InfluxDB CSV missing _time column")
	}
	var records []UsageRecord
	for {
		row, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if timeIdx >= len(row) || row[timeIdx] == "" {
			continue
		}
		ts, err := time.Parse(time.RFC3339, row[timeIdx])
		if err != nil {
			continue
		}
		records = append(records, UsageRecord{
			Timestamp:        ts,
			GridImport:       readCSVFloat(row, idx, "sigen_0_si_total_imported_energy"),
			SolarExp:         readCSVFloat(row, idx, "sigen_0_si_total_exported_energy"),
			SolarGen:         readCSVFloat(row, idx, "sigen_0_si_total_third_party_pv_generation"),
			BatteryDischarge: readCSVFloat(row, idx, "sigen_0_si_total_discharged_energy"),
		})
	}
	return records, nil
}

func readCSVFloat(row []string, idx map[string]int, col string) float64 {
	i, ok := idx[col]
	if !ok || i >= len(row) || row[i] == "" {
		return 0
	}
	v, _ := strconv.ParseFloat(row[i], 64)
	if v < 0 || mathIsNaN(v) || mathIsInf(v) {
		return 0
	}
	return v
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func mathIsNaN(v float64) bool { return v != v }
func mathIsInf(v float64) bool { return v > 1e308 || v < -1e308 }
