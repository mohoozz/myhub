package service

import (
	"strings"
	"testing"
)

func TestParseRange(t *testing.T) {
	const size = 1000
	cases := []struct {
		header    string
		wantStart int64
		wantEnd   int64
		wantErr   bool
	}{
		{"", 0, 999, false},             // 无 Range 全量
		{"bytes=0-99", 0, 99, false},    // 普通区间
		{"bytes=500-", 500, 999, false}, // 开放区间
		{"bytes=-100", 900, 999, false}, // 后缀区间
		{"bytes=-2000", 0, 999, false},  // 后缀超过文件大小
		{"bytes=0-9999", 0, 999, false}, // end 超出截断
		{"bytes=999-999", 999, 999, false},
		{"bytes=1000-", 0, 0, true},          // start 越界
		{"bytes=500-100", 0, 0, true},        // end < start
		{"items=0-10", 0, 0, true},           // 非 bytes 单位
		{"bytes=0-10,20-30", 0, 0, true},     // 多区间不支持
		{"bytes=abc-def", 0, 0, true},        // 非数字
		{"bytes=-", 0, 0, true},              // 空后缀
		{"bytes=--100", 0, 0, true},          // 畸形
	}
	for _, tc := range cases {
		start, end, err := ParseRange(tc.header, size)
		if tc.wantErr {
			if err == nil {
				t.Errorf("ParseRange(%q) 应报错，得到 [%d,%d]", tc.header, start, end)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseRange(%q) 意外报错: %v", tc.header, err)
			continue
		}
		if start != tc.wantStart || end != tc.wantEnd {
			t.Errorf("ParseRange(%q) = [%d,%d]，期望 [%d,%d]", tc.header, start, end, tc.wantStart, tc.wantEnd)
		}
	}
}

func TestSrtToVTT(t *testing.T) {
	srt := "1\r\n00:00:01,000 --> 00:00:03,000\r\nHello\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,500\r\nWorld\r\n"
	vtt := string(srtToVTT([]byte(srt)))
	if vtt[:6] != "WEBVTT" {
		t.Error("应包含 WEBVTT 头")
	}
	if !containsAll(vtt, "00:00:01.000 --> 00:00:03.000", "00:00:04.000 --> 00:00:06.500") {
		t.Errorf("时间戳转换不正确:\n%s", vtt)
	}
}

func containsAll(s string, subs ...string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}

func TestStreamContentType(t *testing.T) {
	if got := StreamContentType("a.mp4"); got != "video/mp4" {
		t.Errorf("mp4 -> %s", got)
	}
	if got := StreamContentType("A.FLAC"); got != "audio/flac" {
		t.Errorf("FLAC -> %s", got)
	}
	if got := StreamContentType("a.xyz"); got != "application/octet-stream" {
		t.Errorf("xyz -> %s", got)
	}
	if !IsPassthrough("v.mkv") || !IsPassthrough("a.ogg") || IsPassthrough("s.srt") {
		t.Error("IsPassthrough 判定错误")
	}
}

func TestHLSSessionIDRoundTrip(t *testing.T) {
	id := HLSSessionID(42, "/视频/movie.mp4")
	sid, p, err := ParseHLSSessionID(id)
	if err != nil {
		t.Fatalf("解码失败: %v", err)
	}
	if sid != 42 || p != "/视频/movie.mp4" {
		t.Errorf("往返不一致: %d %q", sid, p)
	}
	if _, _, err := ParseHLSSessionID("!!!invalid"); err == nil {
		t.Error("非法 ID 应报错")
	}
}
