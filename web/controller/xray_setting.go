package controller

import (
	"encoding/json"
	"strconv"
	"time"

	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/web/service"

	"github.com/gin-gonic/gin"
)

// XraySettingController handles Xray configuration and settings operations.
type XraySettingController struct {
	XraySettingService service.XraySettingService
	SettingService     service.SettingService
	InboundService     service.InboundService
	OutboundService    service.OutboundService
	XrayService        service.XrayService
	WarpService        service.WarpService
	VPNGateService     service.VPNGateService
	OpenVPNService     service.OpenVPNService
}

// NewXraySettingController creates a new XraySettingController and initializes its routes.
func NewXraySettingController(g *gin.RouterGroup) *XraySettingController {
	a := &XraySettingController{}
	a.initRouter(g)
	return a
}

// initRouter sets up the routes for Xray settings management.
func (a *XraySettingController) initRouter(g *gin.RouterGroup) {
	g = g.Group("/xray")
	g.GET("/getDefaultJsonConfig", a.getDefaultXrayConfig)
	g.GET("/getOutboundsTraffic", a.getOutboundsTraffic)
	g.GET("/getXrayResult", a.getXrayResult)

	g.POST("/", a.getXraySetting)
	g.POST("/warp/:action", a.warp)
	g.POST("/vpngate/list", a.vpngateList)
	g.POST("/vpngate/:action", a.vpngate)
	g.POST("/update", a.updateSetting)
	g.POST("/resetOutboundsTraffic", a.resetOutboundsTraffic)
	g.POST("/testOutbound", a.testOutbound)
}

// getXraySetting retrieves the Xray configuration template, inbound tags, and outbound test URL.
func (a *XraySettingController) getXraySetting(c *gin.Context) {
	xraySetting, err := a.SettingService.GetXrayConfigTemplate()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.getSettings"), err)
		return
	}
	// Older versions of this handler embedded the raw DB value as
	// `xraySetting` in the response without checking if the value
	// already had that wrapper shape. When the frontend saved it
	// back through the textarea verbatim, the wrapper got persisted
	// and every subsequent save nested another layer, which is what
	// eventually produced the blank Xray Settings page in #4059.
	// Strip any such wrapper here, and heal the DB if we found one so
	// the next read is O(1) instead of climbing the same pile again.
	if unwrapped := service.UnwrapXrayTemplateConfig(xraySetting); unwrapped != xraySetting {
		if saveErr := a.XraySettingService.SaveXraySetting(unwrapped); saveErr == nil {
			xraySetting = unwrapped
		} else {
			// Don't fail the read — just serve the unwrapped value
			// and leave the DB healing for a later save.
			xraySetting = unwrapped
		}
	}
	inboundTags, err := a.InboundService.GetInboundTags()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.getSettings"), err)
		return
	}
	clientReverseTags, err := a.InboundService.GetClientReverseTags()
	if err != nil {
		clientReverseTags = "[]"
	}
	outboundTestUrl, _ := a.SettingService.GetXrayOutboundTestUrl()
	if outboundTestUrl == "" || outboundTestUrl == "https://www.google.com/generate_204" {
		outboundTestUrl = service.DefaultXrayOutboundTestURL
	}
	securityAlertsEnable, _ := a.SettingService.GetSecurityAlertsEnable()
	xrayResponse := map[string]any{
		"xraySetting":          json.RawMessage(xraySetting),
		"inboundTags":          json.RawMessage(inboundTags),
		"clientReverseTags":    json.RawMessage(clientReverseTags),
		"outboundTestUrl":      outboundTestUrl,
		"securityAlertsEnable": securityAlertsEnable,
	}
	result, err := json.Marshal(xrayResponse)
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.getSettings"), err)
		return
	}
	jsonObj(c, string(result), nil)
}

// updateSetting updates the Xray configuration settings.
func (a *XraySettingController) updateSetting(c *gin.Context) {
	xraySetting := c.PostForm("xraySetting")
	if err := a.XraySettingService.SaveXraySetting(xraySetting); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.modifySettings"), err)
		return
	}
	outboundTestUrl := c.PostForm("outboundTestUrl")
	if outboundTestUrl == "" {
		outboundTestUrl = service.DefaultXrayOutboundTestURL
	}
	if err := a.SettingService.SetXrayOutboundTestUrl(outboundTestUrl); err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.modifySettings"), err)
		return
	}
	jsonMsg(c, I18nWeb(c, "pages.settings.toasts.modifySettings"), nil)
}

// getDefaultXrayConfig retrieves the default Xray configuration.
func (a *XraySettingController) getDefaultXrayConfig(c *gin.Context) {
	defaultJsonConfig, err := a.SettingService.GetDefaultXrayConfig()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.getSettings"), err)
		return
	}
	jsonObj(c, defaultJsonConfig, nil)
}

// getXrayResult retrieves the current Xray service result.
func (a *XraySettingController) getXrayResult(c *gin.Context) {
	jsonObj(c, a.XrayService.GetXrayResult(), nil)
}

// warp handles Cloudflare WARP account and outbound setup.
func (a *XraySettingController) warp(c *gin.Context) {
	action := c.Param("action")
	var resp string
	var err error

	switch action {
	case "data":
		resp, err = a.WarpService.GetWarpData()
	case "del":
		err = a.WarpService.DelWarpData()
	case "config":
		resp, err = a.WarpService.GetWarpConfig()
	case "reg":
		resp, err = a.WarpService.RegWarp(c.PostForm("privateKey"), c.PostForm("publicKey"))
	case "license":
		resp, err = a.WarpService.SetWarpLicense(c.PostForm("license"))
	default:
		err = common.NewError("unknown warp action")
	}

	jsonObj(c, resp, err)
}

func (a *XraySettingController) vpngateList(c *gin.Context) {
	a.OpenVPNService.PrepareVPNGateOpenVPN()
	servers, err := a.VPNGateService.ListServersWithUnavailable(c.PostForm("refresh") == "true", c.PostForm("showUnavailable") == "true")
	jsonObj(c, servers, err)
}

func (a *XraySettingController) vpngate(c *gin.Context) {
	action := c.Param("action")
	var resp any
	var err error

	switch action {
	case "start":
		var server service.VPNGateServer
		err = json.Unmarshal([]byte(c.PostForm("server")), &server)
		if err == nil {
			ruleMode := c.PostForm("ruleMode")
			var selectedCountries []string
			_ = json.Unmarshal([]byte(c.PostForm("selectedCountries")), &selectedCountries)
			fallbackEnable := c.PostForm("fallbackEnable") == "true"
			resp, err = a.OpenVPNService.StartVPNGate(server, ruleMode, selectedCountries, fallbackEnable)
		}
	case "test":
		var server service.VPNGateServer
		err = json.Unmarshal([]byte(c.PostForm("server")), &server)
		if err == nil {
			ok, latency := service.TestVPNGateOpenVPN(server)
			resp = map[string]any{"success": ok, "delay": latency}
		}
	case "get_settings":
		interval, errVal := a.SettingService.GetVPNGateRefreshInterval()
		if errVal != nil {
			interval = 120
		}
		ruleMode, errVal := a.SettingService.GetVPNGateRuleMode()
		if errVal != nil || !isValidVPNGateRuleMode(ruleMode) {
			ruleMode = "default"
		}
		countriesStr, errVal := a.SettingService.GetVPNGateSelectedCountries()
		if errVal != nil {
			countriesStr = "[]"
		}
		var selectedCountries []string
		_ = json.Unmarshal([]byte(countriesStr), &selectedCountries)
		fallbackEnable, errVal := a.SettingService.GetVPNGateFallbackEnable()
		if errVal != nil {
			fallbackEnable = true
		}
		resp = map[string]any{
			"refreshInterval":   interval,
			"ruleMode":          ruleMode,
			"selectedCountries": selectedCountries,
			"fallbackEnable":    fallbackEnable,
		}
	case "save_settings":
		if intervalStr, ok := c.GetPostForm("refreshInterval"); ok {
			interval, errVal := strconv.Atoi(intervalStr)
			if errVal != nil || interval < 15 || interval > 4320 {
				interval = 120
			}
			err = a.SettingService.SetVPNGateRefreshInterval(interval)
		}
		if err == nil {
			if ruleMode, ok := c.GetPostForm("ruleMode"); ok {
				if !isValidVPNGateRuleMode(ruleMode) {
					ruleMode = "default"
				}
				err = a.SettingService.SetVPNGateRuleMode(ruleMode)
			}
		}
		if err == nil {
			if countriesStr, ok := c.GetPostForm("selectedCountries"); ok {
				var selectedCountries []string
				if errVal := json.Unmarshal([]byte(countriesStr), &selectedCountries); errVal != nil {
					countriesStr = "[]"
				}
				err = a.SettingService.SetVPNGateSelectedCountries(countriesStr)
			}
		}
		if err == nil {
			if fallbackEnable, ok := c.GetPostForm("fallbackEnable"); ok {
				err = a.SettingService.SetVPNGateFallbackEnable(fallbackEnable == "true")
			}
		}
		resp = map[string]any{"success": err == nil}
	case "status":
		status := a.OpenVPNService.VPNGateStatus()
		resp = &status
	case "cancel":
		status := a.OpenVPNService.CancelVPNGate()
		resp = &status
	case "continue":
		status := a.OpenVPNService.ContinueVPNGateWithAll()
		resp = &status
	case "stop":
		status := a.OpenVPNService.StopVPNGate()
		resp = &status
	case "uninstall":
		err = a.OpenVPNService.UninstallVPNGate()
		status := a.OpenVPNService.VPNGateStatus()
		resp = &status
	default:
		err = common.NewError("unknown vpngate action")
	}

	jsonObj(c, resp, err)
}

func isValidVPNGateRuleMode(ruleMode string) bool {
	return ruleMode == "default" || ruleMode == "fixed"
}

// getOutboundsTraffic retrieves the traffic statistics for outbounds.
func (a *XraySettingController) getOutboundsTraffic(c *gin.Context) {
	outboundsTraffic, err := a.OutboundService.GetOutboundsTraffic()
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.getOutboundTrafficError"), err)
		return
	}
	jsonObj(c, outboundsTraffic, nil)
}

// resetOutboundsTraffic resets the traffic statistics for the specified outbound tag.
func (a *XraySettingController) resetOutboundsTraffic(c *gin.Context) {
	tag := c.PostForm("tag")
	err := a.OutboundService.ResetOutboundTraffic(tag)
	if err != nil {
		jsonMsg(c, I18nWeb(c, "pages.settings.toasts.resetOutboundTrafficError"), err)
		return
	}
	jsonObj(c, "", nil)
}

// testOutbound tests an outbound configuration and returns the delay/response time.
// Optional form "allOutbounds": JSON array of all outbounds; used to resolve sockopt.dialerProxy dependencies.
func (a *XraySettingController) testOutbound(c *gin.Context) {
	outboundJSON := c.PostForm("outbound")
	allOutboundsJSON := c.PostForm("allOutbounds")
	useLatestManaged := c.PostForm("useLatestManaged") != "false"

	if outboundJSON == "" {
		jsonMsg(c, I18nWeb(c, "somethingWentWrong"), common.NewError("outbound parameter is required"))
		return
	}

	if useLatestManaged {
		if templateConfig, err := a.SettingService.GetXrayConfigTemplate(); err == nil {
			outboundJSON, allOutboundsJSON = syncManagedOutboundTestConfig(outboundJSON, allOutboundsJSON, templateConfig)
		}
	}

	// Load the test URL from server settings to prevent SSRF via user-controlled URLs
	testURL, _ := a.SettingService.GetXrayOutboundTestUrl()

	result, err := a.OutboundService.TestOutbound(outboundJSON, testURL, allOutboundsJSON)
	if err != nil {
		jsonMsg(c, I18nWeb(c, "somethingWentWrong"), err)
		return
	}

	if useLatestManaged && result != nil && !result.Success {
		a.repairManagedOutboundAfterFailedTest(outboundJSON)
	}
	jsonObj(c, result, nil)
}

func (a *XraySettingController) repairManagedOutboundAfterFailedTest(outboundJSON string) {
	var outbound map[string]any
	if err := json.Unmarshal([]byte(outboundJSON), &outbound); err != nil {
		return
	}
	switch outbound["tag"] {
	case "warp":
		go func() {
			time.Sleep(500 * time.Millisecond)
			a.WarpService.RepairWarp()
		}()
	case "vpngate":
		a.OpenVPNService.CheckAndRepairVPNGate()
	}
}

func syncManagedOutboundTestConfig(outboundJSON, allOutboundsJSON, templateConfig string) (string, string) {
	var outbound map[string]any
	if err := json.Unmarshal([]byte(outboundJSON), &outbound); err != nil {
		return outboundJSON, allOutboundsJSON
	}
	tag, _ := outbound["tag"].(string)
	if tag != "vpngate" && tag != "warp" {
		return outboundJSON, allOutboundsJSON
	}

	var configMap map[string]any
	if err := json.Unmarshal([]byte(service.UnwrapXrayTemplateConfig(templateConfig)), &configMap); err != nil {
		return outboundJSON, allOutboundsJSON
	}
	templateOutbounds, _ := configMap["outbounds"].([]any)
	var latest any
	for _, item := range templateOutbounds {
		itemMap, ok := item.(map[string]any)
		if ok && itemMap["tag"] == tag {
			latest = item
			break
		}
	}
	if latest == nil {
		return outboundJSON, allOutboundsJSON
	}
	if latestJSON, err := json.Marshal(latest); err == nil {
		outboundJSON = string(latestJSON)
	}

	outbounds := templateOutbounds
	var postedOutbounds []any
	if allOutboundsJSON != "" && json.Unmarshal([]byte(allOutboundsJSON), &postedOutbounds) == nil && len(postedOutbounds) > 0 {
		outbounds = postedOutbounds
	}
	replaced := false
	for i, item := range outbounds {
		itemMap, ok := item.(map[string]any)
		if ok && itemMap["tag"] == tag {
			outbounds[i] = latest
			replaced = true
			break
		}
	}
	if !replaced {
		outbounds = append(outbounds, latest)
	}
	if outboundsJSON, err := json.Marshal(outbounds); err == nil {
		allOutboundsJSON = string(outboundsJSON)
	}
	return outboundJSON, allOutboundsJSON
}
