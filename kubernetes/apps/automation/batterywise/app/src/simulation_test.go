package main

import "testing"

func TestRunSimulationUsesSydneyTimezone(t *testing.T) {
	data := generateSampleData(2)
	result := RunSimulation(data, Scenario{
		Name: "test",
		Plan: Plan{
			Name:         "Seasonal TOU",
			SupplyCharge: 1.023,
			FeedInTariff: 0.028,
			Windows: []TOUWindow{
				{StartHour: 0, EndHour: 6, StartMinute: 0, EndMinute: 360, Rate: 0.08, Label: "EV Rate"},
				{StartHour: 6, EndHour: 15, StartMinute: 360, EndMinute: 900, Rate: 0.4081, Label: "Off-Peak"},
				{StartHour: 15, EndHour: 21, StartMinute: 900, EndMinute: 1260, Rate: 0.6127, Label: "Peak", Months: []int{1, 2, 3, 6, 7, 8, 11, 12}},
				{StartHour: 15, EndHour: 21, StartMinute: 900, EndMinute: 1260, Rate: 0.4081, Label: "Off-Peak", Months: []int{4, 5, 9, 10}},
				{StartHour: 21, EndHour: 24, StartMinute: 1260, EndMinute: 1440, Rate: 0.4081, Label: "Off-Peak"},
			},
		},
		Battery: BatteryConfig{
			CapacityKWh:    16,
			UsablePercent:  98,
			RoundTripEff:   90,
			MaxChargeKW:    5,
			MaxDischargeKW: 5,
			CostDollars:    12000,
		},
		Strategy: Strategy{
			Name:               "test",
			AlwaysCaptureSolar: true,
			Rules: []StrategyRule{
				{Type: "time", Action: "charge", StartHour: 0, EndHour: 6, SOCTarget: 100},
				{Type: "time", Action: "discharge", StartHour: 15, EndHour: 21, SOCFloor: 0},
			},
		},
	})

	if result.DaysSimulated != 2 {
		t.Fatalf("DaysSimulated = %d, want 2", result.DaysSimulated)
	}
	if len(result.HourlyProfile) != 24 {
		t.Fatalf("HourlyProfile length = %d, want 24", len(result.HourlyProfile))
	}
}
