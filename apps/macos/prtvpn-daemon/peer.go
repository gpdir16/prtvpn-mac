package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/libbsm.h>
#include <Security/Security.h>

// 하드닝된 런타임으로 실행 중인지 나타내는 코드 서명 플래그 (kern/cs_blobs.h 의 CS_RUNTIME)
#define PRTVPN_CS_RUNTIME 0x00010000

// 소켓 반대편 프로세스의 코드 서명이 요구 조건을 만족하는지 확인함.
// pid 가 아니라 audit token 으로 프로세스를 지정하므로 pid 재사용으로 속일 수 없음.
// 0 이면 통과, 그 외에는 실패 단계(음수) 또는 OSStatus.
static int prtvpnVerifyPeer(int fd, const char *requirementText) {
	audit_token_t token;
	socklen_t length = sizeof(token);
	if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0) {
		return -1;
	}

	CFDataRef tokenData = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
	const void *keys[] = {kSecGuestAttributeAudit};
	const void *values[] = {tokenData};
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef text = CFStringCreateWithCString(NULL, requirementText, kCFStringEncodingUTF8);

	SecCodeRef code = NULL;
	SecRequirementRef requirement = NULL;
	CFDictionaryRef info = NULL;
	int result = -2;

	OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
	if (status != errSecSuccess) {
		result = (int)status;
		goto done;
	}
	status = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
	if (status != errSecSuccess) {
		result = (int)status;
		goto done;
	}
	status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
	if (status != errSecSuccess) {
		result = (int)status;
		goto done;
	}

	// 하드닝된 런타임이 아니면 DYLD_INSERT_LIBRARIES 등으로 다른 코드가 끼어들 수 있으므로 거부함.
	status = SecCodeCopySigningInformation(code, kSecCSDynamicInformation, &info);
	if (status != errSecSuccess) {
		result = (int)status;
		goto done;
	}
	CFNumberRef flagsNumber = CFDictionaryGetValue(info, kSecCodeInfoStatus);
	uint32_t flags = 0;
	if (flagsNumber == NULL || !CFNumberGetValue(flagsNumber, kCFNumberSInt32Type, &flags)) {
		result = -3;
		goto done;
	}
	if ((flags & PRTVPN_CS_RUNTIME) == 0) {
		result = -4;
		goto done;
	}
	result = 0;

done:
	if (info) CFRelease(info);
	if (requirement) CFRelease(requirement);
	if (code) CFRelease(code);
	CFRelease(text);
	CFRelease(attributes);
	CFRelease(tokenData);
	return result;
}
*/
import "C"

import (
	"fmt"
	"net"
	"unsafe"
)

// verifyPeer 는 접속한 프로세스가 설치 때 고정된 코드 서명 요구 조건을 만족하는 앱인지 확인함.
func verifyPeer(c *net.UnixConn, requirement string) error {
	if requirement == "" {
		return fmt.Errorf("코드 서명 요구 조건이 설정되지 않음")
	}
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	text := C.CString(requirement)
	defer C.free(unsafe.Pointer(text))

	result := -1
	if err := raw.Control(func(fd uintptr) {
		result = int(C.prtvpnVerifyPeer(C.int(fd), text))
	}); err != nil {
		return err
	}
	switch result {
	case 0:
		return nil
	case -4:
		return fmt.Errorf("하드닝된 런타임으로 서명되지 않은 프로세스")
	default:
		return fmt.Errorf("코드 서명 검증 실패 (%d)", result)
	}
}
