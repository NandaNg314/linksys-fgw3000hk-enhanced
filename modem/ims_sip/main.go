package main

import (
	"bytes"
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

type SmsMsg struct {
	Index   int    `json:"index"`
	Indices string `json:"indices"`
	Storage string `json:"storage"`
	Sender  string `json:"sender"`
	Date    string `json:"date"`
	Code    string `json:"code"`
	Content string `json:"content"`
}

const (
	imsInboxFile    = "/data/ims_inbox.json"
	imsInboxLock    = "/tmp/.ims_inbox.lock"
	deletedSigsFile = "/data/.deleted_ims_sigs"
	atLockFile      = "/tmp/.sms_at.lock"
	cachedImsiFile  = "/tmp/.cached_imsi"
	logFilePath     = "/tmp/ims_sip.log"
	statusFilePath  = "/tmp/ims_sip.status"
	pidFilePath     = "/tmp/ims_sip.pid"
	instanceLock    = "/tmp/.ims_sip.lock"
	imsIfName       = "rmnet_data0"
	imsMuxID        = 1
	imsEpType       = 4 // DATA_EP_TYPE_BAM_DMUX (embedded IPA)
	imsIfaceID      = 1 // rmnet_ipa0 EPID
	imsProfileIdx   = 3 // 3GPP profile 3 = dedicated modem-side ims

	afQipcrtr       = 42
	qmiSvcWds       = 1
	qmiSvcUim       = 11
	qmiNodeModem    = 3
	wdsBindMuxPort  = 0x00A2
	wdsSetIPFamily  = 0x004D
	wdsModProfile   = 0x0028
	wdsGetProfile   = 0x002B
	wdsStartNetIf   = 0x0020
	wdsStopNetIf    = 0x0021
	wdsGetPktStatus = 0x0022
	wdsGetCurSet    = 0x002D
	uimAuthenticate = 0x0034
)

var (
	cstZone          = time.FixedZone("CST", 8*3600)
	seenFingerprints = map[string]bool{}
	reCodeKW         = regexp.MustCompile(`(?i)(?:验证码|校验码|动态码|确认码|随机码|授权码|激活码|安全码|动态密码|认证码|提取码|code)\s*[:：为是\s=\-_]*\s*([0-9]{4,8})`)
	reCodeRev        = regexp.MustCompile(`([0-9]{4,8})\s*(?:[，,。！!]|为|是|作为|即为)?\s*(?:您|本次|登录|注册|修改|操作|验证)?\s*(?:的)?\s*(?:验证码|校验码|动态码|动态密码|确认码|安全码)`)
	reCodeFallback   = regexp.MustCompile(`\b([0-9]{4,6})\b`)
)

func logf(format string, args ...interface{}) {
	ts := time.Now().In(cstZone).Format("2006-01-02 15:04:05")
	line := fmt.Sprintf("[%s] "+format+"\n", append([]interface{}{ts}, args...)...)
	fmt.Print(line)
	if st, err := os.Stat(logFilePath); err == nil && st.Size() > 262144 {
		if data, rerr := os.ReadFile(logFilePath); rerr == nil && len(data) > 131072 {
			_ = os.WriteFile(logFilePath, data[len(data)-131072:], 0644)
		}
	}
	if f, err := os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644); err == nil {
		_, _ = f.WriteString(line)
		_ = f.Close()
	}
}

func writeStatus(state, detail string) {
	ts := time.Now().In(cstZone).Format("2006-01-02 15:04:05")
	_ = os.WriteFile(statusFilePath, []byte(fmt.Sprintf("%s|%s|%s\n", ts, state, detail)), 0644)
}

func withFlock(lockPath string, fn func() error) error {
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

func isDeletedSms(sender, sctsDate, content string) bool {
	data, err := os.ReadFile(deletedSigsFile)
	if err != nil {
		return false
	}
	sig := fmt.Sprintf("%s_%s_%s", sctsDate, sender, content)
	return strings.Contains(string(data), sig)
}

func decodeSCTS(b []byte) string {
	if len(b) < 7 {
		return time.Now().In(cstZone).Format("2006-01-02 15:04:05")
	}
	sw := func(x byte) int { return int(x&0x0F)*10 + int((x>>4)&0x0F) }
	return fmt.Sprintf("%04d-%02d-%02d %02d:%02d:%02d",
		2000+sw(b[0]), sw(b[1]), sw(b[2]), sw(b[3]), sw(b[4]), sw(b[5]))
}

func extractSmsCode(content string) string {
	if m := reCodeKW.FindStringSubmatch(content); len(m) >= 2 {
		return m[1]
	}
	if m := reCodeRev.FindStringSubmatch(content); len(m) >= 2 {
		return m[1]
	}
	if m := reCodeFallback.FindStringSubmatch(content); len(m) >= 2 {
		return m[1]
	}
	return ""
}

func saveImsSms(sender, sctsDate, content, fp string) {
	if fp != "" && seenFingerprints[fp] {
		return
	}
	if fp != "" {
		if len(seenFingerprints) > 200 {
			seenFingerprints = map[string]bool{}
		}
		seenFingerprints[fp] = true
	}

	_ = withFlock(imsInboxLock, func() error {
		if isDeletedSms(sender, sctsDate, content) {
			return nil
		}
		var list []SmsMsg
		if data, err := os.ReadFile(imsInboxFile); err == nil && len(bytes.TrimSpace(data)) > 0 {
			_ = json.Unmarshal(data, &list)
		}
		for _, item := range list {
			if item.Sender == sender && item.Date == sctsDate && item.Content == content {
				return nil
			}
		}
		idx := 900
		if len(list) > 0 {
			idx = list[len(list)-1].Index + 1
			if idx > 999 || idx < 900 {
				idx = 900
			}
		}
		msg := SmsMsg{
			Index:   idx,
			Indices: fmt.Sprintf("%d", idx),
			Storage: "IMS",
			Sender:  sender,
			Date:    sctsDate,
			Code:    extractSmsCode(content),
			Content: content,
		}
		list = append(list, msg)
		if len(list) > 20 {
			list = list[len(list)-20:]
		}
		b, err := json.Marshal(list)
		if err != nil {
			return err
		}
		tmp := imsInboxFile + ".tmp"
		if err := os.WriteFile(tmp, b, 0644); err != nil {
			return err
		}
		return os.Rename(tmp, imsInboxFile)
	})
}

// --- QRTR / QMI client ---

type sockaddrQrtr struct {
	Family uint16
	Pad    uint16
	Node   uint32
	Port   uint32
}

type qmiClient struct {
	fd   int
	node uint32
	port uint32
	txn  uint16
}

func lookupQrtrPort(service uint32) (uint32, uint32, error) {
	out, err := exec.Command("qrtr-lookup").Output()
	if err != nil {
		return 0, 0, err
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 5 {
			svc, err1 := strconv.ParseUint(fields[0], 10, 32)
			node, err2 := strconv.ParseUint(fields[3], 10, 32)
			port, err3 := strconv.ParseUint(fields[4], 10, 32)
			if err1 == nil && err2 == nil && err3 == nil && uint32(svc) == service {
				return uint32(node), uint32(port), nil
			}
		}
	}
	return 0, 0, fmt.Errorf("qrtr service %d not found", service)
}

func newQmiClient(service uint32) (*qmiClient, error) {
	node, port, err := lookupQrtrPort(service)
	if err != nil {
		return nil, err
	}
	fd, err := syscall.Socket(afQipcrtr, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return nil, err
	}
	tv := syscall.Timeval{Sec: 5, Usec: 0}
	_ = syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	return &qmiClient{fd: fd, node: node, port: port, txn: 1}, nil
}

func (c *qmiClient) close() {
	if c != nil && c.fd >= 0 {
		_ = syscall.Close(c.fd)
		c.fd = -1
	}
}

func qmiTLV(t byte, val []byte) []byte {
	b := make([]byte, 3+len(val))
	b[0] = t
	binary.LittleEndian.PutUint16(b[1:3], uint16(len(val)))
	copy(b[3:], val)
	return b
}

func qmiParseTLVs(payload []byte) map[byte][]byte {
	res := make(map[byte][]byte)
	off := 0
	for off+3 <= len(payload) {
		t := payload[off]
		l := int(binary.LittleEndian.Uint16(payload[off+1 : off+3]))
		off += 3
		if off+l > len(payload) {
			break
		}
		res[t] = payload[off : off+l]
		off += l
	}
	return res
}

func (c *qmiClient) call(msgID uint16, tlvs []byte) (map[byte][]byte, uint16, error) {
	c.txn++
	if c.txn == 0 {
		c.txn = 1
	}
	txnID := c.txn

	pkt := make([]byte, 7+len(tlvs))
	pkt[0] = 0x00 // Request
	binary.LittleEndian.PutUint16(pkt[1:3], txnID)
	binary.LittleEndian.PutUint16(pkt[3:5], msgID)
	binary.LittleEndian.PutUint16(pkt[5:7], uint16(len(tlvs)))
	copy(pkt[7:], tlvs)

	sa := sockaddrQrtr{Family: afQipcrtr, Node: c.node, Port: c.port}
	_, _, errno := syscall.Syscall6(syscall.SYS_SENDTO,
		uintptr(c.fd),
		uintptr(unsafe.Pointer(&pkt[0])),
		uintptr(len(pkt)),
		0,
		uintptr(unsafe.Pointer(&sa)),
		unsafe.Sizeof(sa),
	)
	if errno != 0 {
		return nil, 0, errno
	}

	buf := make([]byte, 4096)
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		r1, _, errno := syscall.Syscall6(syscall.SYS_RECVFROM,
			uintptr(c.fd),
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(len(buf)),
			0, 0, 0,
		)
		if errno != 0 {
			return nil, 0, errno
		}
		n := int(r1)
		if n < 7 {
			continue
		}
		flags := buf[0]
		rTxn := binary.LittleEndian.Uint16(buf[1:3])
		rMsg := binary.LittleEndian.Uint16(buf[3:5])
		rLen := int(binary.LittleEndian.Uint16(buf[5:7]))
		if flags != 0x02 || rTxn != txnID || rMsg != msgID {
			continue
		}
		if 7+rLen > n {
			rLen = n - 7
		}
		parsed := qmiParseTLVs(buf[7 : 7+rLen])
		var qmiErr uint16
		if resTLV, ok := parsed[0x02]; ok && len(resTLV) >= 4 {
			resCode := binary.LittleEndian.Uint16(resTLV[0:2])
			errCode := binary.LittleEndian.Uint16(resTLV[2:4])
			if resCode != 0 {
				qmiErr = errCode
			}
		}
		return parsed, qmiErr, nil
	}
	return nil, 0, errors.New("qmi response timeout")
}

// --- WDS Embedded IMS PDN Manager ---

type wdsSession struct {
	client *qmiClient
	handle uint32
}

func ensureImsProfile(c *qmiClient) {
	// Check if profile 3 exists; if not, create it via AT+CGDCONT=3,"IPV6","ims"
	_, qerr, err := c.call(wdsGetProfile, qmiTLV(0x01, []byte{0, imsProfileIdx}))
	if err != nil || qerr != 0 {
		_ = runATLocked(fmt.Sprintf(`AT+CGDCONT=%d,"IPV6","ims"`, imsProfileIdx))
	}
	// Ensure im_cn_flag=1 (TLV 0x1F=1) so network returns P-CSCF in PCO
	modTLVs := append(qmiTLV(0x01, []byte{0, imsProfileIdx}), qmiTLV(0x14, []byte("ims"))...)
	modTLVs = append(modTLVs, qmiTLV(0x11, []byte{2})...) // PDP_TYPE = IPV6
	modTLVs = append(modTLVs, qmiTLV(0x1F, []byte{1})...) // IM_CN_FLAG = 1
	_, _, _ = c.call(wdsModProfile, modTLVs)
}

func startEmbeddedImsPDN() (*wdsSession, string, []string, error) {
	c, err := newQmiClient(qmiSvcWds)
	if err != nil {
		return nil, "", nil, err
	}

	ensureImsProfile(c)

	// 1. BindMuxDataPort: TLV 0x10 (ep_type=4, iface_id=1), TLV 0x11 (mux_id=1), TLV 0x13 (client_type=0)
	epVal := make([]byte, 8)
	binary.LittleEndian.PutUint32(epVal[0:4], imsEpType)
	binary.LittleEndian.PutUint32(epVal[4:8], imsIfaceID)
	ctVal := make([]byte, 4)
	binary.LittleEndian.PutUint32(ctVal, 0)
	bindTLVs := append(qmiTLV(0x10, epVal), qmiTLV(0x11, []byte{imsMuxID})...)
	bindTLVs = append(bindTLVs, qmiTLV(0x13, ctVal)...)
	if _, qerr, err := c.call(wdsBindMuxPort, bindTLVs); err != nil || qerr != 0 {
		c.close()
		return nil, "", nil, fmt.Errorf("BindMuxDataPort err=%v qmi=0x%x", err, qerr)
	}

	// 2. SetClientIPFamilyPref = 6 (IPv6)
	if _, qerr, err := c.call(wdsSetIPFamily, qmiTLV(0x01, []byte{6})); err != nil || qerr != 0 {
		c.close()
		return nil, "", nil, fmt.Errorf("SetClientIPFamilyPref err=%v qmi=0x%x", err, qerr)
	}

	// 3. StartNetworkInterface: Profile 3 (ims)
	tlvs, qerr, err := c.call(wdsStartNetIf, qmiTLV(0x31, []byte{imsProfileIdx}))
	if err != nil {
		c.close()
		return nil, "", nil, fmt.Errorf("StartNetworkInterface err=%v", err)
	}
	if qerr != 0 {
		var reason uint16
		if v, ok := tlvs[0x11]; ok && len(v) >= 4 {
			reason = binary.LittleEndian.Uint16(v[2:4])
		}
		c.close()
		return nil, "", nil, fmt.Errorf("StartNetworkInterface qmi=0x%x reason=%d", qerr, reason)
	}
	var handle uint32
	if v, ok := tlvs[0x01]; ok && len(v) >= 4 {
		handle = binary.LittleEndian.Uint32(v[0:4])
	}
	sess := &wdsSession{client: c, handle: handle}

	// Prefer AT+CGCONTRDP=3 (gives exact IMS_IP + P-CSCFs), fallback to QMI GetCurrentSettings
	imsIP, pcscfs := queryCgpdpViaAT(imsProfileIdx)
	qmiIP, qmiPcscfs, _ := sess.getSettings()
	if imsIP == "" {
		imsIP = qmiIP
	}
	if len(pcscfs) == 0 {
		pcscfs = qmiPcscfs
	}
	if imsIP == "" || len(pcscfs) == 0 {
		sess.stop()
		return nil, "", nil, fmt.Errorf("ims settings incomplete (ip=%q pcscfs=%v)", imsIP, pcscfs)
	}
	return sess, imsIP, pcscfs, nil
}

func (s *wdsSession) isConnected() bool {
	if s == nil || s.client == nil {
		return false
	}
	tlvs, qerr, err := s.client.call(wdsGetPktStatus, nil)
	if err != nil || qerr != 0 {
		return false
	}
	if v, ok := tlvs[0x01]; ok && len(v) >= 1 {
		return v[0] == 2 // CONNECTED
	}
	return false
}

func (s *wdsSession) getSettings() (imsIP string, pcscfs []string, err error) {
	mask := make([]byte, 4)
	binary.LittleEndian.PutUint32(mask, 0x0001FFFF)
	tlvs, qerr, err := s.client.call(wdsGetCurSet, qmiTLV(0x10, mask))
	if err != nil || qerr != 0 {
		return "", nil, fmt.Errorf("GetCurrentSettings err=%v qmi=0x%x", err, qerr)
	}
	// TLV 0x25: IPv6 address (16 bytes addr + 1 byte prefix len)
	if v, ok := tlvs[0x25]; ok && len(v) >= 16 {
		imsIP = net.IP(v[:16]).String()
	}
	// TLV 0x22 or 0x2D: P-CSCF IPv6 address list (count uint8 + N*16 bytes)
	for _, tag := range []byte{0x22, 0x2D} {
		if v, ok := tlvs[tag]; ok && len(v) >= 17 {
			cnt := int(v[0])
			for i := 0; i < cnt && 1+(i+1)*16 <= len(v); i++ {
				ip := net.IP(v[1+i*16 : 1+(i+1)*16])
				if ip != nil && !ip.IsUnspecified() {
					pcscfs = append(pcscfs, ip.String())
				}
			}
			if len(pcscfs) > 0 {
				break
			}
		}
	}
	return imsIP, pcscfs, nil
}

func (s *wdsSession) stop() {
	if s == nil || s.client == nil {
		return
	}
	if s.handle != 0 {
		h := make([]byte, 4)
		binary.LittleEndian.PutUint32(h, s.handle)
		_, _, _ = s.client.call(wdsStopNetIf, qmiTLV(0x01, h))
		s.handle = 0
	}
	s.client.close()
	s.client = nil
}

func runATLocked(atCmd string) string {
	var outStr string
	_ = withFlock(atLockFile, func() error {
		out, err := exec.Command("atcli", atCmd).Output()
		if err == nil {
			outStr = string(out)
		}
		return nil
	})
	return outStr
}

func getIMSI() string {
	if b, err := os.ReadFile(cachedImsiFile); err == nil {
		s := strings.TrimSpace(string(b))
		if len(s) >= 14 && len(s) <= 16 {
			return s
		}
	}
	raw := runATLocked("AT+CIMI")
	re := regexp.MustCompile(`\b(\d{14,15})\b`)
	if m := re.FindStringSubmatch(raw); len(m) >= 2 {
		_ = os.WriteFile(cachedImsiFile, []byte(m[1]+"\n"), 0644)
		return m[1]
	}
	return ""
}

func parseDottedIPv6(s string) string {
	s = strings.TrimSpace(s)
	parts := strings.Split(s, ".")
	if len(parts) != 16 {
		return ""
	}
	ip := make([]byte, 16)
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > 255 {
			return ""
		}
		ip[i] = byte(n)
	}
	parsed := net.IP(ip)
	if parsed.IsUnspecified() {
		return ""
	}
	return parsed.String()
}

func queryCgpdpViaAT(cid int) (imsIP string, pcscfs []string) {
	raw := runATLocked(fmt.Sprintf("AT+CGCONTRDP=%d", cid))
	for _, line := range strings.Split(raw, "\n") {
		idx := strings.Index(line, "+CGCONTRDP:")
		if idx < 0 {
			continue
		}
		fields := strings.Split(line[idx+len("+CGCONTRDP:"):], ",")
		for i := 3; i < len(fields); i++ {
			ip := parseDottedIPv6(fields[i])
			if ip == "" {
				continue
			}
			if i == 3 {
				imsIP = ip
			} else if i >= 7 {
				pcscfs = append(pcscfs, ip)
			}
		}
	}
	return imsIP, pcscfs
}

func setupNet(imsIP string, pcscfs, oldPcscfs []string) {
	_ = os.WriteFile("/proc/sys/net/ipv6/conf/"+imsIfName+"/disable_ipv6", []byte("0\n"), 0644)
	_ = os.WriteFile("/proc/sys/net/ipv6/conf/"+imsIfName+"/accept_ra", []byte("0\n"), 0644)
	_ = exec.Command("ip", "link", "set", "dev", imsIfName, "up").Run()
	_ = exec.Command("ip", "-6", "addr", "flush", "dev", imsIfName, "scope", "global").Run()
	_ = exec.Command("ip", "-6", "addr", "replace", imsIP+"/64", "dev", imsIfName).Run()
	for _, oldP := range oldPcscfs {
		_ = exec.Command("ip", "-6", "route", "del", oldP+"/128", "dev", imsIfName).Run()
	}
	for _, p := range pcscfs {
		_ = exec.Command("ip", "-6", "route", "replace", p+"/128", "dev", imsIfName, "src", imsIP).Run()
	}
}

func cleanupNet(pcscfs []string) {
	for _, p := range pcscfs {
		_ = exec.Command("ip", "-6", "route", "del", p+"/128", "dev", imsIfName).Run()
	}
	_ = exec.Command("ip", "-6", "addr", "flush", "dev", imsIfName, "scope", "global").Run()
}

// --- AKA via direct QRTR UIM (with HTTP fallback) ---

func qrtrAka(randBytes, autnBytes []byte) ([]byte, error) {
	c, err := newQmiClient(qmiSvcUim)
	if err != nil {
		return httpAkaFallback(randBytes, autnBytes)
	}
	defer c.close()

	aid, _ := hex.DecodeString("a0000000871002ff86ffff89ffffffff")
	tlv1Val := append([]byte{0x00, byte(len(aid))}, aid...)
	ap := make([]byte, 0, 2+len(randBytes)+len(autnBytes))
	ap = append(ap, byte(len(randBytes)))
	ap = append(ap, randBytes...)
	ap = append(ap, byte(len(autnBytes)))
	ap = append(ap, autnBytes...)
	tlv2Val := make([]byte, 3+len(ap))
	tlv2Val[0] = 0x03
	binary.LittleEndian.PutUint16(tlv2Val[1:3], uint16(len(ap)))
	copy(tlv2Val[3:], ap)

	tlvs := append(qmiTLV(0x01, tlv1Val), qmiTLV(0x02, tlv2Val)...)
	respTLVs, qerr, err := c.call(uimAuthenticate, tlvs)
	if err != nil || qerr != 0 {
		return httpAkaFallback(randBytes, autnBytes)
	}
	v, ok := respTLVs[0x11]
	if !ok || len(v) < 4 {
		return httpAkaFallback(randBytes, autnBytes)
	}
	cl := int(binary.LittleEndian.Uint16(v[0:2]))
	if 2+cl > len(v) || cl < 2 {
		return nil, fmt.Errorf("aka short response")
	}
	cardResp := v[2 : 2+cl]
	if cardResp[0] == 0xDB && len(cardResp) >= 2 {
		rl := int(cardResp[1])
		if 2+rl <= len(cardResp) {
			return cardResp[2 : 2+rl], nil
		}
	}
	return nil, fmt.Errorf("aka unexpected tag 0x%02x", cardResp[0])
}

func httpAkaFallback(randBytes, autnBytes []byte) ([]byte, error) {
	u := fmt.Sprintf("http://10.10.10.3:55102/cgi-bin/aka?rand=%s&autn=%s",
		hex.EncodeToString(randBytes), hex.EncodeToString(autnBytes))
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	reRes := regexp.MustCompile(`RES=([0-9a-fA-F]+)`)
	if m := reRes.FindStringSubmatch(string(body)); len(m) >= 2 {
		return hex.DecodeString(m[1])
	}
	return nil, fmt.Errorf("aka failed: %s", string(body))
}

func md5Hex(data []byte) string {
	h := md5.Sum(data)
	return hex.EncodeToString(h[:])
}

func decodeBCD(b []byte, digits int) string {
	var sb strings.Builder
	for _, x := range b {
		lo := x & 0x0F
		hi := (x >> 4) & 0x0F
		if lo <= 9 {
			sb.WriteByte('0' + lo)
		}
		if hi <= 9 && sb.Len() < digits {
			sb.WriteByte('0' + hi)
		}
	}
	res := sb.String()
	if len(res) > digits {
		return res[:digits]
	}
	return res
}

func decodeGSM7(data []byte, septets int, skipBits int) string {
	var out []rune
	for i := 0; i < septets; i++ {
		bitPos := i*7 + skipBits
		byteIdx := bitPos / 8
		bitOff := bitPos % 8
		if byteIdx >= len(data) {
			break
		}
		val := data[byteIdx] >> bitOff
		if bitOff > 1 && byteIdx+1 < len(data) {
			val |= data[byteIdx+1] << (8 - bitOff)
		}
		out = append(out, rune(val&0x7F))
	}
	return string(out)
}

func decodeUCS2(data []byte) string {
	if len(data)%2 != 0 {
		data = data[:len(data)-1]
	}
	u16 := make([]uint16, len(data)/2)
	for i := 0; i < len(u16); i++ {
		u16[i] = uint16(data[2*i])<<8 | uint16(data[2*i+1])
	}
	return string(utf16.Decode(u16))
}

func parseRpDataSms(body []byte) (rpMR byte, hasMR bool, sender, sctsDate, text, fp string) {
	sctsDate = time.Now().In(cstZone).Format("2006-01-02 15:04:05")
	if len(body) < 6 {
		return 0, false, "unknown", sctsDate, "(too short)", ""
	}
	rpMR = body[1]
	hasMR = (body[0] == 0x01)
	off := 2
	if off >= len(body) {
		return rpMR, hasMR, "unknown", sctsDate, "", ""
	}
	off += 1 + int(body[off])
	if off >= len(body) {
		return rpMR, hasMR, "unknown", sctsDate, "", ""
	}
	off += 1 + int(body[off])
	if off >= len(body) {
		return rpMR, hasMR, "unknown", sctsDate, "", ""
	}
	tpduLen := int(body[off])
	off++
	if off+tpduLen > len(body) {
		tpduLen = len(body) - off
	}
	tpdu := body[off : off+tpduLen]
	if len(tpdu) < 12 {
		return rpMR, hasMR, "unknown", sctsDate, "(short tpdu)", ""
	}
	hasUDHI := (tpdu[0] & 0x40) != 0
	p := 1
	oaLen := int(tpdu[p])
	p++
	oaType := tpdu[p]
	p++
	oaBytes := (oaLen + 1) / 2
	if p+oaBytes > len(tpdu) {
		return rpMR, hasMR, "unknown", sctsDate, "", ""
	}
	sender = decodeBCD(tpdu[p:p+oaBytes], oaLen)
	if (oaType & 0x70) == 0x10 {
		sender = "+" + sender
	}
	p += oaBytes
	if p+9 > len(tpdu) {
		return rpMR, hasMR, sender, sctsDate, "", ""
	}
	dcs := tpdu[p+1]
	sctsDate = decodeSCTS(tpdu[p+2 : p+9])
	sctsHex := hex.EncodeToString(tpdu[p+2 : p+9])
	p += 9
	if p >= len(tpdu) {
		return rpMR, hasMR, sender, sctsDate, "", ""
	}
	udl := int(tpdu[p])
	p++
	ud := tpdu[p:]

	udhBytes := 0
	if hasUDHI && len(ud) > 0 {
		udhBytes = 1 + int(ud[0])
		if udhBytes > len(ud) {
			udhBytes = len(ud)
		}
	}
	if (dcs & 0x0C) == 0x08 {
		if udhBytes < len(ud) {
			text = decodeUCS2(ud[udhBytes:])
		}
	} else {
		fillBits := (7 - (udhBytes*8)%7) % 7
		septets := udl - (udhBytes*8+6)/7
		if udhBytes < len(ud) && septets > 0 {
			text = decodeGSM7(ud[udhBytes:], septets, fillBits)
		}
	}
	fp = sender + "|" + sctsHex + "|" + text
	return rpMR, hasMR, sender, sctsDate, text, fp
}

func extractHeader(msg, name string) string {
	for _, line := range strings.Split(msg, "\r\n") {
		if strings.HasPrefix(strings.ToLower(line), strings.ToLower(name)+":") {
			return strings.TrimSpace(line[len(name)+1:])
		}
	}
	return ""
}

func extractURI(hdrVal string) string {
	if m := regexp.MustCompile(`<([^>]+)>`).FindStringSubmatch(hdrVal); len(m) >= 2 {
		return m[1]
	}
	return strings.TrimSpace(strings.Split(hdrVal, ";")[0])
}

func sendRpAck(conn *net.UDPConn, myIP, imsi, myURI, inCallID, targetHdr, serviceRoute string, rpMR byte) {
	targetURI := extractURI(targetHdr)
	if targetURI == "" {
		return
	}
	ackBody := []byte{0x02, rpMR, 0x41, 0x02, 0x00, 0x00}
	callID := fmt.Sprintf("rpack-%d-%d@%s", time.Now().Unix(), rpMR, myIP)
	routeLine := ""
	if serviceRoute != "" {
		routeLine = "Route: " + serviceRoute + "\r\n"
	}
	msg := fmt.Sprintf(
		"MESSAGE %s SIP/2.0\r\n"+
			"Via: SIP/2.0/UDP [%s]:5060;branch=z9hG4bKrpack%d%d\r\n"+
			"%s"+
			"Max-Forwards: 70\r\n"+
			"P-Preferred-Identity: <%s>\r\n"+
			"From: <%s>;tag=ack%d\r\n"+
			"To: <%s>\r\n"+
			"Call-ID: %s\r\n"+
			"In-Reply-To: %s\r\n"+
			"CSeq: 1 MESSAGE\r\n"+
			"Contact: <sip:%s@[%s]:5060>;+g.3gpp.smsip\r\n"+
			"Content-Type: application/vnd.3gpp.sms\r\n"+
			"Content-Length: %d\r\n\r\n",
		targetURI, myIP, time.Now().Unix()%10000, rpMR, routeLine,
		myURI, myURI, rpMR, targetURI, callID, inCallID, imsi, myIP, len(ackBody))
	pkt := append([]byte(msg), ackBody...)
	_, _ = conn.Write(pkt)
	logf("-> Sent RP-ACK+DELIVER-REPORT (MR=0x%02x) to %s", rpMR, targetURI)
}

func doRegister(conn *net.UDPConn, myIP, imsi, realm, impi, impu string, expiresSec int) (ok bool, serviceRoute, assocURI string) {
	callID := fmt.Sprintf("goims-%d-%d@%s", time.Now().Unix(), expiresSec, myIP)
	reg1 := fmt.Sprintf(
		"REGISTER sip:%s SIP/2.0\r\n"+
			"Via: SIP/2.0/UDP [%s]:5060;branch=z9hG4bKreg1%d\r\n"+
			"Max-Forwards: 70\r\n"+
			"From: <%s>;tag=t1\r\n"+
			"To: <%s>\r\n"+
			"Call-ID: %s\r\n"+
			"CSeq: 1 REGISTER\r\n"+
			"Contact: <sip:%s@[%s]:5060>;+g.3gpp.smsip\r\n"+
			"Authorization: Digest username=\"%s\",realm=\"%s\",nonce=\"\",uri=\"sip:%s\",response=\"\"\r\n"+
			"Expires: %d\r\n"+
			"Content-Length: 0\r\n\r\n",
		realm, myIP, time.Now().Unix()%1000, impu, impu, callID, imsi, myIP, impi, realm, realm, expiresSec)

	if _, err := conn.Write([]byte(reg1)); err != nil {
		return false, "", ""
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil {
		return false, "", ""
	}
	resp1 := string(buf[:n])
	if strings.HasPrefix(resp1, "SIP/2.0 200") {
		logf("REGISTER(exp=%d): SIP/2.0 200 OK (direct)", expiresSec)
		return true, extractHeader(resp1, "Service-Route"), extractURI(extractHeader(resp1, "P-Associated-URI"))
	}
	m := regexp.MustCompile(`nonce="([^"]+)"`).FindStringSubmatch(resp1)
	if len(m) < 2 {
		return false, "", ""
	}
	nonceB64 := m[1]
	nonceRaw, err := base64.StdEncoding.DecodeString(nonceB64)
	if err != nil || len(nonceRaw) < 32 {
		return false, "", ""
	}
	resBytes, err := qrtrAka(nonceRaw[:16], nonceRaw[16:32])
	if err != nil {
		logf("AKA err: %v", err)
		return false, "", ""
	}

	ha1 := md5Hex(append([]byte(fmt.Sprintf("%s:%s:", impi, realm)), resBytes...))
	ha2 := md5Hex([]byte(fmt.Sprintf("REGISTER:sip:%s", realm)))
	var authHdr string
	if strings.Contains(resp1, "qop=") {
		cnonce, nc := "0a4f113b", "00000001"
		authResp := md5Hex([]byte(fmt.Sprintf("%s:%s:%s:%s:auth:%s", ha1, nonceB64, nc, cnonce, ha2)))
		authHdr = fmt.Sprintf(`Digest username="%s",realm="%s",nonce="%s",uri="sip:%s",response="%s",algorithm=AKAv1-MD5,qop=auth,nc=%s,cnonce="%s"`,
			impi, realm, nonceB64, realm, authResp, nc, cnonce)
	} else {
		authResp := md5Hex([]byte(fmt.Sprintf("%s:%s:%s", ha1, nonceB64, ha2)))
		authHdr = fmt.Sprintf(`Digest username="%s",realm="%s",nonce="%s",uri="sip:%s",response="%s",algorithm=AKAv1-MD5`,
			impi, realm, nonceB64, realm, authResp)
	}

	reg2 := fmt.Sprintf(
		"REGISTER sip:%s SIP/2.0\r\n"+
			"Via: SIP/2.0/UDP [%s]:5060;branch=z9hG4bKreg2%d\r\n"+
			"Max-Forwards: 70\r\n"+
			"From: <%s>;tag=t1\r\n"+
			"To: <%s>\r\n"+
			"Call-ID: %s\r\n"+
			"CSeq: 2 REGISTER\r\n"+
			"Contact: <sip:%s@[%s]:5060>;+g.3gpp.smsip\r\n"+
			"Authorization: %s\r\n"+
			"Expires: %d\r\n"+
			"Content-Length: 0\r\n\r\n",
		realm, myIP, time.Now().Unix()%1000, impu, impu, callID, imsi, myIP, authHdr, expiresSec)

	if _, err := conn.Write([]byte(reg2)); err != nil {
		return false, "", ""
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n2, err := conn.Read(buf)
	if err != nil {
		return false, "", ""
	}
	resp2 := string(buf[:n2])
	logf("REGISTER(exp=%d): %s", expiresSec, strings.Split(resp2, "\r\n")[0])
	if strings.HasPrefix(resp2, "SIP/2.0 200") {
		return true, extractHeader(resp2, "Service-Route"), extractURI(extractHeader(resp2, "P-Associated-URI"))
	}
	return false, "", ""
}

func main() {
	// Acquire kernel-level non-blocking exclusive lock BEFORE touching PID, status, log, or QMI
	// so concurrent boot/CGI launches never spawn a second instance that overwrites status.
	instLockFh, lerr := os.OpenFile(instanceLock, os.O_CREATE|os.O_RDWR, 0644)
	if lerr != nil {
		os.Exit(1)
	}
	if err := syscall.Flock(int(instLockFh.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		os.Exit(0)
	}
	defer instLockFh.Close()

	_ = os.WriteFile(pidFilePath, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644)
	defer os.Remove(pidFilePath)

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	var activeSess *wdsSession
	var prevPcscfs []string

	cleanupAll := func() {
		if activeSess != nil {
			activeSess.stop()
			activeSess = nil
		}
		cleanupNet(prevPcscfs)
		writeStatus("STOPPED", "signal")
		_ = os.Remove(pidFilePath)
	}

	go func() {
		<-sigCh
		logf("Received shutdown signal, cleaning up WDS session...")
		cleanupAll()
		os.Exit(0)
	}()

	onceMode := false
	pulseTTL := 12 * time.Second
	for _, arg := range os.Args[1:] {
		if arg == "--once" || arg == "--pulse" {
			onceMode = true
		} else if strings.HasPrefix(arg, "--ttl=") {
			if v, err := strconv.Atoi(strings.TrimPrefix(arg, "--ttl=")); err == nil && v >= 5 && v <= 60 {
				pulseTTL = time.Duration(v) * time.Second
			}
		}
	}

	logf("=== ims_sip_modem started (iface=%s, mux=%d, once=%v) ===", imsIfName, imsMuxID, onceMode)
	if onceMode {
		writeStatus("PULSING", "starting_pdn")
	} else {
		writeStatus("STARTING", "initializing")
	}

	for {
		imsi := getIMSI()
		if imsi == "" {
			writeStatus("WAITING", "no_imsi")
			logf("Waiting for SIM IMSI...")
			if onceMode {
				writeStatus("PULSE_FAILED", "no_imsi")
				return
			}
			time.Sleep(5 * time.Second)
			continue
		}

		sess, imsIP, pcscfs, err := startEmbeddedImsPDN()
		if err != nil {
			writeStatus("WAITING", err.Error())
			logf("Waiting for embedded ims PDN: %v", err)
			if onceMode {
				writeStatus("PULSE_FAILED", err.Error())
				return
			}
			time.Sleep(10 * time.Second)
			continue
		}
		activeSess = sess
		setupNet(imsIP, pcscfs, prevPcscfs)
		prevPcscfs = pcscfs

		mnc, mcc := imsi[3:5], imsi[0:3]
		if len(mnc) == 2 {
			mnc = "0" + mnc
		}
		realm := fmt.Sprintf("ims.mnc%s.mcc%s.3gppnetwork.org", mnc, mcc)
		impi := fmt.Sprintf("%s@%s", imsi, realm)
		impu := fmt.Sprintf("sip:%s@%s", imsi, realm)

		var conn *net.UDPConn
		registered := false
		var serviceRoute, myURI string
		for _, p := range pcscfs {
			laddr, err1 := net.ResolveUDPAddr("udp6", fmt.Sprintf("[%s]:5060", imsIP))
			raddr, err2 := net.ResolveUDPAddr("udp6", fmt.Sprintf("[%s]:5060", p))
			if err1 != nil || err2 != nil {
				continue
			}
			c, err := net.DialUDP("udp6", laddr, raddr)
			if err != nil {
				logf("DialUDP %s -> %s err: %v", imsIP, p, err)
				continue
			}
			if ok, sr, au := doRegister(c, imsIP, imsi, realm, impi, impu, 3600); ok {
				conn = c
				registered = true
				serviceRoute = sr
				if au != "" {
					myURI = au
				} else {
					myURI = impu
				}
				stLabel := "REGISTERED"
				if onceMode {
					stLabel = "PULSING"
				}
				writeStatus(stLabel, fmt.Sprintf("pcscf=%s ims_ip=%s uri=%s", p, imsIP, myURI))
				logf("Registered via P-CSCF %s (IMS_IP=%s, URI=%s, once=%v)", p, imsIP, myURI, onceMode)
				break
			}
			_ = c.Close()
		}

		if !registered {
			writeStatus("REGISTER_FAILED", imsIP)
			sess.stop()
			activeSess = nil
			cleanupNet(prevPcscfs)
			if onceMode {
				return
			}
			time.Sleep(15 * time.Second)
			continue
		}

		pulseStart := time.Now()
		pulseDeadline := pulseStart.Add(pulseTTL)
		pulseMaxDeadline := pulseStart.Add(25 * time.Second)
		rxCount := 0

		lastReg := time.Now()
		lastCheck := time.Now()
		buf := make([]byte, 8192)
		for {
			if onceMode && time.Now().After(pulseDeadline) {
				logf("Pulse window complete (rx=%d), sending SIP REGISTER(Expires:0) and stopping PDN...", rxCount)
				_, _, _ = doRegister(conn, imsIP, imsi, realm, impi, impu, 0)
				_ = conn.Close()
				sess.stop()
				activeSess = nil
				cleanupNet(prevPcscfs)
				writeStatus("PULSE_IDLE", fmt.Sprintf("rx=%d ims_ip=%s", rxCount, imsIP))
				return
			}
			if !onceMode && time.Since(lastCheck) > 60*time.Second {
				if !sess.isConnected() {
					logf("IMS PDN disconnected, re-establishing...")
					break
				}
				curIP, _, gerr := sess.getSettings()
				if gerr == nil && curIP != "" {
					pOld := net.ParseIP(imsIP)
					pNew := net.ParseIP(curIP)
					if pOld != nil && pNew != nil && !bytes.Equal(pOld.To16()[:8], pNew.To16()[:8]) {
						logf("IMS_IP prefix drifted %s -> %s, re-registering...", imsIP, curIP)
						break
					}
				}
				lastCheck = time.Now()
			}
			if !onceMode && time.Since(lastReg) > 25*time.Minute {
				if ok, sr, _ := doRegister(conn, imsIP, imsi, realm, impi, impu, 3600); !ok {
					logf("Periodic re-REGISTER failed, reconnecting...")
					break
				} else if sr != "" {
					serviceRoute = sr
				}
				lastReg = time.Now()
			}
			readWait := 30 * time.Second
			if onceMode {
				rem := time.Until(pulseDeadline)
				if rem <= 0 {
					continue
				}
				if rem < 2*time.Second {
					readWait = rem
				} else {
					readWait = 2 * time.Second
				}
			}
			_ = conn.SetReadDeadline(time.Now().Add(readWait))
			n, err := conn.Read(buf)
			if err != nil {
				if ne, ok := err.(net.Error); ok && ne.Timeout() {
					continue
				}
				logf("UDP read error: %v, reconnecting...", err)
				break
			}
			pkt := buf[:n]
			idx := bytes.Index(pkt, []byte("\r\n\r\n"))
			if idx < 0 {
				continue
			}
			hdr := string(pkt[:idx])
			body := pkt[idx+4:]
			firstLine := strings.Split(hdr, "\r\n")[0]
			if strings.HasPrefix(firstLine, "SIP/2.0 ") {
				logf("<- %s", firstLine)
				continue
			}
			if strings.HasPrefix(firstLine, "MESSAGE ") || strings.HasPrefix(firstLine, "NOTIFY ") {
				okResp := fmt.Sprintf("SIP/2.0 200 OK\r\nVia: %s\r\nFrom: %s\r\nTo: %s;tag=rx1\r\nCall-ID: %s\r\nCSeq: %s\r\nContent-Length: 0\r\n\r\n",
					extractHeader(hdr, "Via"), extractHeader(hdr, "From"), extractHeader(hdr, "To"),
					extractHeader(hdr, "Call-ID"), extractHeader(hdr, "CSeq"))
				_, _ = conn.Write([]byte(okResp))

				if strings.HasPrefix(firstLine, "MESSAGE ") && len(body) > 0 {
					rpMR, hasMR, sender, sctsDate, text, fp := parseRpDataSms(body)
					if hasMR {
						targetHdr := extractHeader(hdr, "P-Asserted-Identity")
						if targetHdr == "" {
							targetHdr = extractHeader(hdr, "From")
						}
						sendRpAck(conn, imsIP, imsi, myURI, extractHeader(hdr, "Call-ID"), targetHdr, serviceRoute, rpMR)
					}
					logf("[5G-IMS-SMS] (%s) From: %s | Text: %s", sctsDate, sender, text)
					saveImsSms(sender, sctsDate, text, fp)
					rxCount++
					if onceMode {
						ext := time.Now().Add(4 * time.Second)
						if ext.After(pulseMaxDeadline) {
							ext = pulseMaxDeadline
						}
						if ext.After(pulseDeadline) {
							pulseDeadline = ext
						}
					}
				}
			}
		}
		_ = conn.Close()
		sess.stop()
		activeSess = nil
		cleanupNet(prevPcscfs)
		if onceMode {
			writeStatus("PULSE_IDLE", fmt.Sprintf("rx=%d", rxCount))
			return
		}
		time.Sleep(3 * time.Second)
	}
}
