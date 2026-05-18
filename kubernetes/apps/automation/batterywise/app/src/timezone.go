package main

import (
	"time"

	_ "time/tzdata"
)

var sydneyTZ = loadSydneyLocation()

func loadSydneyLocation() *time.Location {
	loc, err := time.LoadLocation("Australia/Sydney")
	if err != nil {
		return time.FixedZone("Australia/Sydney", 10*60*60)
	}
	return loc
}

func sydneyLocation() *time.Location {
	return sydneyTZ
}
