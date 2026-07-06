package service

import (
	"sort"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

type VPNGateService struct{}

const (
	vpnGateAPIURL     = "https://www.vpngate.net/api/iphone/"
	vpnGateCacheTTL   = 5 * time.Minute
	vpnGateMaxServers = 100
)

type VPNGateServer struct {
	HostName          string `json:"hostName"`
	IP                string `json:"ip"`
	CountryLong       string `json:"countryLong"`
	CountryShort      string `json:"countryShort"`
	CountryShortLower string `json:"countryShortLower"`
	NumSessions       int64  `json:"numSessions"`
	ISP               string `json:"isp"`
	ASN               string `json:"asn"`
	IPType            string `json:"ipType"`
	LocalPing         int64  `json:"localPing"`
	Proto             string `json:"proto"`
	Port              string `json:"port"`
	OpenVPNConfig     string `json:"openVPNConfig"`
	HttpLatency       int64  `json:"httpLatency"`
	CountryLongZH    string `json:"countryLongZH"`
}

var vpnGateCache struct {
	sync.Mutex
	servers []VPNGateServer
	expires time.Time
}

func (s *VPNGateService) ListServers(refresh bool) ([]VPNGateServer, error) {
	return s.ListServersWithUnavailable(refresh, false)
}

func (s *VPNGateService) ListServersWithUnavailable(refresh bool, includeUnavailable bool) ([]VPNGateServer, error) {
	vpnGateCache.Lock()
	defer vpnGateCache.Unlock()

	if !refresh && time.Now().Before(vpnGateCache.expires) {
		if includeUnavailable {
			return cloneVPNGateServers(vpnGateCache.servers), nil
		}
		return cloneVPNGateServers(filterVPNGateAvailable(vpnGateCache.servers)), nil
	}

	servers, err := loadVPNGateServers()
	if err != nil {
		return nil, err
	}
	vpnGateCache.servers = limitVPNGateServers(servers, vpnGateMaxServers)
	vpnGateCache.expires = time.Now().Add(vpnGateCacheTTL)

	lastFetchTimeMutex.Lock()
	lastFetchTime = time.Now()
	lastFetchTimeMutex.Unlock()

	if includeUnavailable {
		return cloneVPNGateServers(vpnGateCache.servers), nil
	}
	return cloneVPNGateServers(filterVPNGateAvailable(vpnGateCache.servers)), nil
}

func loadVPNGateServers() ([]VPNGateServer, error) {
	servers, err := (VPNGateFetcher{}).Fetch()
	if err != nil {
		return nil, err
	}
	servers = (VPNGateValidator{}).Validate(servers)
	sortVPNGateServers(servers)

	return servers, nil
}

func sortVPNGateServers(servers []VPNGateServer) {
	sort.Slice(servers, func(i, j int) bool {
		pi, pj := servers[i].LocalPing, servers[j].LocalPing
		if pi == -1 && pj == -1 {
			return servers[i].NumSessions > servers[j].NumSessions
		}
		if pi == -1 {
			return false
		}
		if pj == -1 {
			return true
		}
		if pi != pj {
			return pi < pj
		}
		return servers[i].NumSessions > servers[j].NumSessions
	})
}

func cloneVPNGateServers(servers []VPNGateServer) []VPNGateServer {
	clone := make([]VPNGateServer, len(servers))
	copy(clone, servers)
	return clone
}

func limitVPNGateServers(servers []VPNGateServer, limit int) []VPNGateServer {
	if limit <= 0 || len(servers) <= limit {
		return servers
	}
	return servers[:limit]
}

func filterVPNGateAvailable(servers []VPNGateServer) []VPNGateServer {
	active := make([]VPNGateServer, 0, len(servers))
	for _, server := range servers {
		if server.LocalPing >= 0 {
			active = append(active, server)
		}
	}
	return active
}

var (
	lastFetchTime      time.Time
	lastFetchTimeMutex sync.Mutex
)

func CheckAndRefreshVPNGate(intervalMinutes int) {
	lastFetchTimeMutex.Lock()
	defer lastFetchTimeMutex.Unlock()

	// Initial load if lastFetchTime is zero
	if lastFetchTime.IsZero() || time.Since(lastFetchTime) >= time.Duration(intervalMinutes)*time.Minute {
		lastFetchTime = time.Now() // Set immediately to prevent duplicate runs
		// Fetch in the background so we do not block the cron scheduler
		go func() {
			logger.Info("[VPNGate] Background periodic node fetching started...")
			vpngateService := &VPNGateService{}
			_, err := vpngateService.ListServers(true) // force refresh and cache
			if err != nil {
				logger.Errorf("[VPNGate] Background periodic node fetch failed: %v", err)
				lastFetchTimeMutex.Lock()
				lastFetchTime = time.Time{} // reset on failure to retry on next check
				lastFetchTimeMutex.Unlock()
			} else {
				logger.Info("[VPNGate] Background periodic node fetch completed successfully.")
			}
		}()
	}
}

func (s *VPNGateService) ClearCache() {
	vpnGateCache.Lock()
	defer vpnGateCache.Unlock()
	vpnGateCache.servers = nil
	vpnGateCache.expires = time.Time{}
}
