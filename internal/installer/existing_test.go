package installer

import (
	"context"
	"testing"
)

func existingTestConfig(t *testing.T) Config {
	c := testConfig(t)
	c.AKS.APIAuthorizedCIDRs = nil
	c.Existing = &ExistingConfig{
		StorageAccount:  "substratestore01",
		NodeClientID:    "11111111-1111-1111-1111-111111111111",
		ControlClientID: "22222222-2222-2222-2222-222222222222",
		TenantID:        "33333333-3333-3333-3333-333333333333",
	}
	return c
}

func TestExistingInfrastructureNeedsNoAzureLookups(t *testing.T) {
	c := existingTestConfig(t)
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	// A nil Runner proves infrastructure() makes no az or kubectl calls.
	i, err := App{Config: c}.infrastructure(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if i.AccountURL != "https://substratestore01.blob.core.windows.net" || i.SnapshotsContainer != "snapshots" ||
		i.AssetsContainer != "assets" || i.ClusterName != c.AKS.ClusterName || i.ResourceGroup != c.Azure.ResourceGroup {
		t.Fatalf("unexpected infrastructure: %+v", i)
	}
}

func TestExistingConfigRejectsBadValues(t *testing.T) {
	for name, mutate := range map[string]func(*Config){
		"storage account": func(c *Config) { c.Existing.StorageAccount = "Bad_Name" },
		"node client id":  func(c *Config) { c.Existing.NodeClientID = "nope" },
		"tenant id":       func(c *Config) { c.Existing.TenantID = "" },
	} {
		t.Run(name, func(t *testing.T) {
			c := existingTestConfig(t)
			mutate(&c)
			if err := c.Validate(); err == nil {
				t.Fatal("expected a validation error")
			}
		})
	}
}

func TestWithoutExistingStillRequiresAPICIDRs(t *testing.T) {
	c := testConfig(t)
	c.AKS.APIAuthorizedCIDRs = nil
	if err := c.Validate(); err == nil {
		t.Fatal("expected the API CIDR requirement to remain for installer-created clusters")
	}
}
