#!/usr/bin/env python3
"""Run pam_authenticate for a service and user, answering every hidden
prompt with a fixed password. Prints "result=<pam code> prompts=<n>".

A stand-in for pamtester that needs nothing beyond libpam (ctypes), so it
runs the same under pam_wrapper locally and in CI.

usage: pam_auth.py <service> <user> <password>
"""
import ctypes
import ctypes.util
import sys

PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
PAM_FAIL_DELAY = 10

DELAY_FUNC = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_uint, ctypes.c_void_p)


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


# Pointer arguments are taken as raw addresses (c_void_p) and cast by hand:
# ctypes' typed double pointers in callbacks can't be written through.
CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


def main():
    service, user, password = sys.argv[1], sys.argv[2], sys.argv[3]
    # Load libpam globally, then resolve its functions through the global
    # symbol table: under pam_wrapper the LD_PRELOADed pam_start must win,
    # and looking symbols up on the libpam handle directly would bypass it.
    ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0", mode=ctypes.RTLD_GLOBAL)
    libpam = ctypes.CDLL(None)
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    libc.calloc.restype = ctypes.c_void_p
    libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    libc.strdup.restype = ctypes.c_void_p
    libc.strdup.argtypes = [ctypes.c_char_p]
    libc.free.argtypes = [ctypes.c_void_p]
    prompts = 0

    def conv(n, messages_addr, responses_addr, _appdata):
        nonlocal prompts
        # Linux-PAM passes messages as an array of pointers to pam_message.
        messages = ctypes.cast(messages_addr, ctypes.POINTER(ctypes.POINTER(PamMessage)))
        # PAM frees the responses, so they must come from the C allocator.
        array = libc.calloc(n, ctypes.sizeof(PamResponse))
        replies = ctypes.cast(array, ctypes.POINTER(PamResponse))
        for i in range(n):
            style = messages[i].contents.msg_style
            if style in (PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON):
                prompts += 1
                replies[i].resp = libc.strdup(password.encode())
        if responses_addr:
            ctypes.cast(responses_addr, ctypes.POINTER(ctypes.c_void_p))[0] = array
        else:
            # Info/error messages may be sent with no reply slot.
            libc.free(array)
        return 0

    # Keep the callback object referenced for the whole transaction; ctypes
    # does not keep it alive through the struct field.
    callback = CONV_FUNC(conv)
    conv_struct = PamConv(callback, None)
    handle = ctypes.c_void_p()
    rc = libpam.pam_start(
        service.encode(), user.encode(), ctypes.byref(conv_struct), ctypes.byref(handle)
    )
    if rc != 0:
        print(f"result=start-failed:{rc} prompts=0")
        return
    # Take over PAM's ~2s delay after a failure; the lockout tests fail on
    # purpose dozens of times. Delay handling isn't what's under test.
    no_delay = DELAY_FUNC(lambda _retval, _usec, _appdata: None)
    libpam.pam_set_item(handle, PAM_FAIL_DELAY, no_delay)
    rc = libpam.pam_authenticate(handle, 0)
    libpam.pam_end(handle, rc)
    print(f"result={rc} prompts={prompts}")


main()
