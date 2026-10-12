package main

import "testing"

func TestIsAllowedHostname(t *testing.T) {
	cases := map[string]bool{
		"vpn-api.proton.me":                           true,
		"verify.proton.me":                            true,
		"VPN-API.Proton.me":                           true,
		"api.protonvpn.ch":                            true,
		"proton.me.example.com":                       false,
		"notproton.me":                                false,
		"bank.example.com":                            false,
		"vpn-api.proton.me\n1.2.3.4 bank.example.com": false,
		"": false,
	}
	for name, want := range cases {
		if got := isAllowedHostname(name); got != want {
			t.Errorf("isAllowedHostname(%q) = %v, want %v", name, got, want)
		}
	}
}
