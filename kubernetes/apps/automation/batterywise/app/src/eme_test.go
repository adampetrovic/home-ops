package main

import "testing"

func TestEMEPlanIDCandidatesAddsNumberedVariantsForBaseID(t *testing.T) {
	candidates := emePlanIDCandidates("OVO704447MRE")
	if len(candidates) != 51 {
		t.Fatalf("len(candidates) = %d, want 51", len(candidates))
	}
	if candidates[0] != "OVO704447MRE" {
		t.Fatalf("first candidate = %q, want base plan ID", candidates[0])
	}
	if candidates[20] != "OVO704447MRE20" {
		t.Fatalf("candidate 20 = %q, want OVO704447MRE20", candidates[20])
	}
}

func TestEMEPlanIDCandidatesDoNotAppendToResolvedID(t *testing.T) {
	candidates := emePlanIDCandidates("OVO704447MRE20")
	if len(candidates) != 1 {
		t.Fatalf("len(candidates) = %d, want 1", len(candidates))
	}
	if candidates[0] != "OVO704447MRE20" {
		t.Fatalf("candidate = %q, want OVO704447MRE20", candidates[0])
	}
}
