package syncers

import (
	"fmt"
	"strings"
)

var strategyOrder = map[string]int{
	"MustRunAs":         0,
	"MustRunAsRange":    1,
	"MustRunAsNonRoot":  2,
	"RunAsAny":          3,
}

func ValidateSCCAgainstCeiling(virtual, ceiling map[string]interface{}) []string {
	if len(ceiling) == 0 {
		return nil
	}

	var violations []string

	boolFields := []string{
		"allowPrivilegedContainer",
		"allowHostNetwork",
		"allowHostPorts",
		"allowHostPID",
		"allowHostIPC",
		"allowHostDirVolumePlugin",
		"allowPrivilegeEscalation",
		"defaultAllowPrivilegeEscalation",
		"readOnlyRootFilesystem",
	}
	for _, field := range boolFields {
		if v := checkBool(virtual, ceiling, field); v != "" {
			violations = append(violations, v)
		}
	}

	listFields := []string{
		"volumes",
		"allowedCapabilities",
		"defaultAddCapabilities",
		"allowedUnsafeSysctls",
	}
	for _, field := range listFields {
		if v := checkList(virtual, ceiling, field); v != "" {
			violations = append(violations, v)
		}
	}

	strategyFields := []string{
		"runAsUser",
		"seLinuxContext",
		"fsGroup",
		"supplementalGroups",
	}
	for _, field := range strategyFields {
		if v := checkStrategy(virtual, ceiling, field); v != "" {
			violations = append(violations, v)
		}
	}

	return violations
}

func checkBool(virtual, ceiling map[string]interface{}, field string) string {
	cVal, ok := ceiling[field]
	if !ok {
		return ""
	}
	cBool, ok := cVal.(bool)
	if !ok {
		return ""
	}
	if cBool {
		return ""
	}
	vVal, ok := virtual[field]
	if !ok {
		return ""
	}
	vBool, _ := vVal.(bool)
	if vBool {
		return fmt.Sprintf("%s: true exceeds ceiling (false)", field)
	}
	return ""
}

func checkList(virtual, ceiling map[string]interface{}, field string) string {
	cVal, ok := ceiling[field]
	if !ok {
		return ""
	}
	allowed := toStringSlice(cVal)

	vVal, ok := virtual[field]
	if !ok {
		return ""
	}
	requested := toStringSlice(vVal)
	if len(requested) == 0 {
		return ""
	}

	allowedSet := make(map[string]struct{}, len(allowed))
	for _, a := range allowed {
		allowedSet[a] = struct{}{}
	}

	var denied []string
	for _, r := range requested {
		if r == "*" {
			if _, ok := allowedSet["*"]; !ok {
				denied = append(denied, "*")
			}
			continue
		}
		if _, ok := allowedSet[r]; !ok {
			if _, ok := allowedSet["*"]; !ok {
				denied = append(denied, r)
			}
		}
	}

	if len(denied) > 0 {
		return fmt.Sprintf("%s: [%s] not allowed by ceiling [%s]",
			field, strings.Join(denied, ", "), strings.Join(allowed, ", "))
	}
	return ""
}

func checkStrategy(virtual, ceiling map[string]interface{}, field string) string {
	cVal, ok := ceiling[field]
	if !ok {
		return ""
	}
	cType := extractStrategyType(cVal)
	if cType == "" {
		return ""
	}

	vVal, ok := virtual[field]
	if !ok {
		return ""
	}
	vType := extractStrategyType(vVal)
	if vType == "" {
		return ""
	}

	cRank, cOK := strategyOrder[cType]
	vRank, vOK := strategyOrder[vType]
	if !cOK || !vOK {
		return ""
	}

	if vRank > cRank {
		return fmt.Sprintf("%s.type: %s is less restrictive than ceiling (%s)", field, vType, cType)
	}
	return ""
}

func extractStrategyType(val interface{}) string {
	m, ok := val.(map[string]interface{})
	if !ok {
		return ""
	}
	t, ok := m["type"]
	if !ok {
		return ""
	}
	s, ok := t.(string)
	if !ok {
		return ""
	}
	return s
}

func toStringSlice(val interface{}) []string {
	slice, ok := val.([]interface{})
	if !ok {
		return nil
	}
	result := make([]string, 0, len(slice))
	for _, item := range slice {
		if s, ok := item.(string); ok {
			result = append(result, s)
		}
	}
	return result
}
