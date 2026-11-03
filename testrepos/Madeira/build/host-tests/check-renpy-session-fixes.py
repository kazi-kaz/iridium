#!/usr/bin/env python3
"""Source checks for the fixes found with Ren'Py (The Tribe, 2026-11-03).

- A press on a window that cannot be brought to the front is delivered, not
  eaten (win32u message_ios.c), and the server's foreground lock no longer
  refuses (wineserver queue_ios.c).
- Touches are mapped through the topmost visible window when no window is
  foreground (win32u driver_ios.c).
- The WASAPI event timer paces on absolute deadlines (audio_null_ios.c).
- An image that finds no room in the JIT pool fails to map (virtual_ios.c).
- The guest main thread is created with a QoS class, not a fixed priority
  (WineProcessBridge.m).
These are textual checks; no Wine runs. Behaviour needs a device run.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]  # testrepos/Madeira


def read(path):
    return (root / path).read_text()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2]


message = read('build/win32u-unix/message_ios.c')
activate = message[message.index('/* Activate the window if needed */'):]
activate = activate[:activate.index('/* send the WM_SETCURSOR message */')]
assert 'if (!set_foreground_window( hwndTop, TRUE, FALSE )) eat_msg = TRUE;' not in activate
failed = activate[activate.index('if (!set_foreground_window( hwndTop, TRUE, FALSE ))'):]
failed = failed[:failed.index('break;')]
assert 'eat_msg = TRUE' not in failed
assert 'set_active_window( hwndTop, NULL, TRUE, TRUE, 0 )' in failed
assert 'get_window_thread( hwndTop, NULL ) == GetCurrentThreadId()' in failed
# the explicit "eat" answers still eat
assert activate.count('eat_msg = TRUE;') == 2

queue = read('build/wineserver/queue_ios.c')
handler = function(queue, 'DECL_HANDLER(set_foreground_window)')
lock = handler[handler.index('if (set_foreground && !req->internal)'):handler.index('reply->previous')]
assert 'STATUS_ACCESS_DENIED' not in lock and '[fg-lock]' in lock
assert 'ERROR_INVALID_WINDOW_HANDLE' in handler

driver = read('build/win32u-unix/driver_ios.c')
fallback = function(driver, 'static HWND winios_input_fallback_window(void)')
assert 'is_window_visible( hwnd )' in fallback and 'GW_HWNDNEXT' in fallback
post = function(driver, 'void winios_drv_post_mouse(')
assert post.index('winios_input_fallback_window()') < post.index('map_window_points(target, NULL, &position, 1, get_thread_dpi());')
assert driver.count('target = winios_input_fallback_window();') == 2

audio = read('build/ntdll-unix/audio_null_ios.c')
loop = function(audio, 'static NTSTATUS ios_timer_loop(void *args)')
assert 'usleep(' not in loop
assert 'mach_wait_until(next)' in loop and 'next += period;' in loop
assert 'pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);' in loop
period = function(audio, 'static uint64_t ios_audio_period_mach(void)')
assert '10000000ull * g_timebase.denom / g_timebase.numer' in period
assert '*p->def_period = 100000;' in audio  # still the 10 ms period the timer paces

virtual = read('build/ntdll-unix/virtual_ios.c')
exhausted = virtual[virtual.index('[jit-pool] EXHAUSTED (image %p'):]
assert exhausted.index('ios_jit_image_exhausted = 1;') < exhausted.index('return -1;')
mapping = function(virtual, 'static NTSTATUS map_image_into_view(')
eager = mapping[mapping.index('eager JIT-copy section'):]
assert 'ios_jit_image_exhausted = 0;' in eager
assert 'status = STATUS_NO_MEMORY;' in eager and 'break;' in eager

bridge = read('app/Madeira/WineProcessBridge.m')
assert 'pthread_attr_setschedparam(&attr, &sched);' not in bridge
assert 'pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0);' in bridge
assert bridge.index('pthread_attr_set_qos_class_np(&attr') < bridge.index('pthread_create(&g_wine_thread, &attr')

print('PASS: presses delivered without foreground, touches mapped without foreground, '
      'audio timer on deadlines, full pool fails the map, guest main thread has a QoS class')
