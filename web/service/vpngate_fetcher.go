package service

import (
	"bytes"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type VPNGateFetcher struct{}

type vpnGateIPResponse struct {
	Status  string `json:"status"`
	ISP     string `json:"isp"`
	Org     string `json:"org"`
	AS      string `json:"as"`
	Hosting bool   `json:"hosting"`
	Query   string `json:"query"`
	Country string `json:"country"`
}

type vpnGateIPInfo struct {
	ISP           string
	ASN           string
	IPType        string
	CountryLongZH string
}

func (VPNGateFetcher) Fetch() ([]VPNGateServer, error) {
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Get(vpnGateAPIURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("VPNGate request failed: %s", resp.Status)
	}

	buf := &bytes.Buffer{}
	if _, err := buf.ReadFrom(resp.Body); err != nil {
		return nil, err
	}

	servers, err := parseVPNGateCSV(buf.String())
	if err != nil {
		return nil, err
	}

	ips := make([]string, 0, len(servers))
	for _, server := range servers {
		ips = append(ips, server.IP)
	}
	ipInfo := fetchVPNGateIPData(ips)
	for i := range servers {
		info, ok := ipInfo[servers[i].IP]
		if !ok {
			servers[i].ISP = "Unknown"
			servers[i].ASN = "Unknown"
			servers[i].IPType = "Unknown"
			continue
		}
		servers[i].ISP = info.ISP
		servers[i].ASN = info.ASN
		servers[i].IPType = info.IPType
		if info.CountryLongZH != "" {
			servers[i].CountryLongZH = info.CountryLongZH
		}
	}

	return servers, nil
}

func parseVPNGateCSV(body string) ([]VPNGateServer, error) {
	start := strings.Index(body, "#HostName")
	if start < 0 {
		return nil, errors.New("VPNGate CSV header not found")
	}
	csvData := body[start:]
	if end := strings.LastIndex(csvData, "*"); end >= 0 {
		csvData = csvData[:end]
	}

	reader := csv.NewReader(strings.NewReader(csvData))
	reader.FieldsPerRecord = -1
	reader.LazyQuotes = true
	records, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(records) < 2 {
		return nil, errors.New("VPNGate returned no servers")
	}

	headers := records[0]
	if len(headers) > 0 {
		headers[0] = strings.TrimPrefix(headers[0], "#")
	}
	col := map[string]int{}
	for i, h := range headers {
		col[h] = i
	}
	get := func(row []string, key string) string {
		i, ok := col[key]
		if !ok || i >= len(row) {
			return ""
		}
		return strings.TrimSpace(row[i])
	}
	getInt := func(row []string, key string) int64 {
		n, _ := strconv.ParseInt(get(row, key), 10, 64)
		return n
	}

	servers := make([]VPNGateServer, 0, len(records)-1)
	for _, row := range records[1:] {
		if len(row) < len(headers)/2 {
			continue
		}
		config := get(row, "OpenVPN_ConfigData_Base64")
		proto, port := parseVPNGateProtoPort(config)
		ip := get(row, "IP")
		if ip == "" {
			continue
		}
		countryShort := get(row, "CountryShort")
		ping := getInt(row, "Ping")
		if ping <= 0 {
			ping = -1
		}
		servers = append(servers, VPNGateServer{
			HostName:          get(row, "HostName"),
			IP:                ip,
			CountryLong:       get(row, "CountryLong"),
			CountryShort:      countryShort,
			CountryShortLower: strings.ToLower(countryShort),
			NumSessions:       getInt(row, "NumVpnSessions"),
			LocalPing:         ping,
			Proto:             proto,
			Port:              port,
			OpenVPNConfig:     config,
		})
	}
	return servers, nil
}

func parseVPNGateProtoPort(base64Config string) (string, string) {
	decoded, err := base64.StdEncoding.DecodeString(base64Config)
	if err != nil {
		return "udp", ""
	}
	proto, port := "udp", ""
	for _, line := range strings.Split(string(decoded), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[0] == "remote" {
			port = fields[2]
			if len(fields) >= 4 && strings.Contains(strings.ToLower(fields[3]), "tcp") {
				proto = "tcp"
			}
		}
		if len(fields) >= 2 && fields[0] == "proto" {
			if strings.Contains(strings.ToLower(fields[1]), "tcp") {
				proto = "tcp"
			} else {
				proto = "udp"
			}
		}
	}
	return proto, port
}

func fetchVPNGateIPData(ips []string) map[string]vpnGateIPInfo {
	result := map[string]vpnGateIPInfo{}
	client := &http.Client{Timeout: 15 * time.Second}
	for i := 0; i < len(ips); i += 100 {
		end := i + 100
		if end > len(ips) {
			end = len(ips)
		}
		payload, _ := json.Marshal(ips[i:end])
		resp, err := client.Post("http://ip-api.com/batch?fields=status,isp,org,as,hosting,query,country&lang=zh-CN", "application/json", bytes.NewReader(payload))
		if err != nil {
			continue
		}
		var rows []vpnGateIPResponse
		err = json.NewDecoder(resp.Body).Decode(&rows)
		resp.Body.Close()
		if err != nil {
			continue
		}
		for _, row := range rows {
			if row.Status != "success" {
				continue
			}
			isp := row.ISP
			if isp == "" {
				isp = row.Org
			}
			if isp == "" {
				isp = "Unknown"
			}
			result[row.Query] = vpnGateIPInfo{
				ISP:           isp,
				ASN:           extractVPNGateASN(row.AS),
				IPType:        determineVPNGateIPType(row.Hosting, row.ISP, row.Org),
				CountryLongZH: row.Country,
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return result
}

func extractVPNGateASN(as string) string {
	if as == "" {
		return "Unknown"
	}
	parts := strings.Fields(as)
	if len(parts) > 0 && strings.HasPrefix(strings.ToUpper(parts[0]), "AS") {
		return parts[0]
	}
	return as
}

func determineVPNGateIPType(hosting bool, isp, org string) string {
	if hosting {
		return "机房IP"
	}
	text := strings.ToLower(isp + " " + org)
	for _, keyword := range []string{"datacenter", "hosting", "cloud", "vps", "amazon", "aws", "google", "microsoft", "azure", "oracle", "linode", "ovh", "vultr", "hetzner", "contabo", "tencent", "alibaba"} {
		if strings.Contains(text, keyword) {
			return "机房IP"
		}
	}
	return "住宅IP"
}
