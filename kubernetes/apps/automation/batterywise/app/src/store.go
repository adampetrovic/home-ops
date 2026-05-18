package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Store manages all persistent data via SQLite.
type Store struct {
	db *sql.DB
}

// NewStore opens (or creates) the database at configDir/batterywise.db.
func NewStore(configDir string) (*Store, error) {
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return nil, fmt.Errorf("create config dir: %w", err)
	}

	dbPath := filepath.Join(configDir, "batterywise.db")
	db, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	// Single writer, many readers
	db.SetMaxOpenConns(1)

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	log.Printf("Database: %s", dbPath)
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

func (s *Store) migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS usage_records (
			id         INTEGER PRIMARY KEY,
			timestamp  TEXT    NOT NULL,
			grid_import_kwh       REAL NOT NULL,
			solar_generation_kwh  REAL NOT NULL DEFAULT 0,
			solar_export_kwh      REAL NOT NULL DEFAULT 0,
			battery_discharge_kwh REAL NOT NULL DEFAULT 0
		)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_records(timestamp)`,

		`CREATE TABLE IF NOT EXISTS datasets (
			id         INTEGER PRIMARY KEY,
			name       TEXT    NOT NULL,
			records    INTEGER NOT NULL DEFAULT 0,
			start_time TEXT,
			end_time   TEXT,
			created_at TEXT    NOT NULL DEFAULT (datetime('now'))
		)`,

		`CREATE TABLE IF NOT EXISTS scenarios (
			id         INTEGER PRIMARY KEY,
			name       TEXT    NOT NULL,
			config     TEXT    NOT NULL,
			created_at TEXT    NOT NULL DEFAULT (datetime('now')),
			updated_at TEXT    NOT NULL DEFAULT (datetime('now'))
		)`,

		`CREATE TABLE IF NOT EXISTS sim_results (
			id          INTEGER PRIMARY KEY,
			scenario_id INTEGER NOT NULL REFERENCES scenarios(id) ON DELETE CASCADE,
			result      TEXT    NOT NULL,
			created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
		)`,
	}
	for _, q := range stmts {
		if _, err := s.db.Exec(q); err != nil {
			return fmt.Errorf("%s: %w", q[:60], err)
		}
	}
	if err := s.ensureUsageColumn("battery_discharge_kwh", "REAL NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	return nil
}

func (s *Store) ensureUsageColumn(name, definition string) error {
	_, err := s.db.Exec(fmt.Sprintf("ALTER TABLE usage_records ADD COLUMN %s %s", name, definition))
	if err != nil && !strings.Contains(strings.ToLower(err.Error()), "duplicate column") {
		return fmt.Errorf("add usage_records.%s: %w", name, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Usage records
// ---------------------------------------------------------------------------

// ReplaceUsageData deletes all existing records and bulk-inserts new ones.
func (s *Store) ReplaceUsageData(records []UsageRecord) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec("DELETE FROM usage_records"); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM datasets"); err != nil {
		return err
	}

	stmt, err := tx.Prepare(`INSERT INTO usage_records (timestamp, grid_import_kwh, solar_generation_kwh, solar_export_kwh, battery_discharge_kwh)
		VALUES (?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, r := range records {
		if _, err := stmt.Exec(r.Timestamp.Format(time.RFC3339), r.GridImport, r.SolarGen, r.SolarExp, r.BatteryDischarge); err != nil {
			return err
		}
	}

	// Metadata row
	if len(records) > 0 {
		_, err = tx.Exec(`INSERT INTO datasets (name, records, start_time, end_time) VALUES (?, ?, ?, ?)`,
			"default", len(records),
			records[0].Timestamp.Format(time.RFC3339),
			records[len(records)-1].Timestamp.Format(time.RFC3339))
		if err != nil {
			return err
		}
	}

	return tx.Commit()
}

// LoadUsageData reads all records ordered by timestamp.
func (s *Store) LoadUsageData() ([]UsageRecord, error) {
	rows, err := s.db.Query(`SELECT timestamp, grid_import_kwh, solar_generation_kwh, solar_export_kwh, battery_discharge_kwh
		FROM usage_records ORDER BY timestamp`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var records []UsageRecord
	for rows.Next() {
		var tsStr string
		var r UsageRecord
		if err := rows.Scan(&tsStr, &r.GridImport, &r.SolarGen, &r.SolarExp, &r.BatteryDischarge); err != nil {
			return nil, err
		}
		r.Timestamp, _ = time.Parse(time.RFC3339, tsStr)
		records = append(records, r)
	}
	return records, rows.Err()
}

// UsageDataStatus returns info about the current dataset.
func (s *Store) UsageDataStatus() (loaded bool, count int, start, end string, days int) {
	row := s.db.QueryRow(`SELECT records, start_time, end_time FROM datasets ORDER BY id DESC LIMIT 1`)
	var startT, endT string
	if err := row.Scan(&count, &startT, &endT); err != nil {
		return false, 0, "", "", 0
	}
	if count == 0 {
		return false, 0, "", "", 0
	}
	t1, _ := time.Parse(time.RFC3339, startT)
	t2, _ := time.Parse(time.RFC3339, endT)
	days = int(t2.Sub(t1).Hours()/24) + 1
	return true, count, startT, endT, days
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

// SaveScenario inserts or updates a scenario. Returns the ID.
func (s *Store) SaveScenario(sc Scenario) (int64, error) {
	cfg, err := json.Marshal(sc)
	if err != nil {
		return 0, err
	}

	// Check if exists by name
	var id int64
	err = s.db.QueryRow(`SELECT id FROM scenarios WHERE name = ?`, sc.Name).Scan(&id)
	if err == nil {
		_, err = s.db.Exec(`UPDATE scenarios SET config = ?, updated_at = datetime('now') WHERE id = ?`, string(cfg), id)
		return id, err
	}

	res, err := s.db.Exec(`INSERT INTO scenarios (name, config) VALUES (?, ?)`, sc.Name, string(cfg))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListScenarios returns all saved scenarios.
func (s *Store) ListScenarios() ([]ScenarioRecord, error) {
	rows, err := s.db.Query(`SELECT id, name, config, created_at, updated_at FROM scenarios ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ScenarioRecord
	for rows.Next() {
		var sr ScenarioRecord
		var cfgStr string
		if err := rows.Scan(&sr.ID, &sr.Name, &cfgStr, &sr.CreatedAt, &sr.UpdatedAt); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(cfgStr), &sr.Config)
		out = append(out, sr)
	}
	return out, rows.Err()
}

// GetScenario returns a single scenario by ID.
func (s *Store) GetScenario(id int64) (ScenarioRecord, error) {
	var sr ScenarioRecord
	var cfgStr string
	err := s.db.QueryRow(`SELECT id, name, config, created_at, updated_at FROM scenarios WHERE id = ?`, id).
		Scan(&sr.ID, &sr.Name, &cfgStr, &sr.CreatedAt, &sr.UpdatedAt)
	if err != nil {
		return sr, err
	}
	json.Unmarshal([]byte(cfgStr), &sr.Config)
	return sr, nil
}

// DeleteScenario removes a scenario and its results.
func (s *Store) DeleteScenario(id int64) error {
	_, err := s.db.Exec(`DELETE FROM scenarios WHERE id = ?`, id)
	return err
}

// ---------------------------------------------------------------------------
// Simulation results
// ---------------------------------------------------------------------------

// SaveResult stores a simulation result for a scenario.
func (s *Store) SaveResult(scenarioID int64, result SimResult) (int64, error) {
	data, err := json.Marshal(result)
	if err != nil {
		return 0, err
	}

	// Replace existing result for this scenario
	s.db.Exec(`DELETE FROM sim_results WHERE scenario_id = ?`, scenarioID)

	res, err := s.db.Exec(`INSERT INTO sim_results (scenario_id, result) VALUES (?, ?)`, scenarioID, string(data))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// GetResult returns the latest result for a scenario.
func (s *Store) GetResult(scenarioID int64) (SimResult, error) {
	var resultStr string
	err := s.db.QueryRow(`SELECT result FROM sim_results WHERE scenario_id = ? ORDER BY id DESC LIMIT 1`, scenarioID).
		Scan(&resultStr)
	if err != nil {
		return SimResult{}, err
	}
	var r SimResult
	json.Unmarshal([]byte(resultStr), &r)
	return r, nil
}

// ScenarioRecord is a scenario with metadata.
type ScenarioRecord struct {
	ID        int64    `json:"id"`
	Name      string   `json:"name"`
	Config    Scenario `json:"config"`
	CreatedAt string   `json:"created_at"`
	UpdatedAt string   `json:"updated_at"`
}
