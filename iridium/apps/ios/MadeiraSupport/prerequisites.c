/* SPDX-License-Identifier: GPL-3.0-or-later
 * Service-manager startup adapted from willfaust/madeira-dock src/scm.c
 * at 3cadfbea700e4da4b04e331dd7ef1ba633dfacef. Copyright 2026 125hz.
 * Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md.
 * Iridium: run only included prerequisites, then the selected game. No Dock client.
 * Optional Steam client stage (experimental): the player's own Steam runs and is
 * signed in before the game starts, then is closed when the game exits.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsvc.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define CAP 32768
static wchar_t executable[CAP], command[CAP], directory[CAP], key[CAP], name[CAP];
static const wchar_t *config;
static void status(const char *phase, UINT run, UINT runs, UINT process, UINT processes)
{
    FILE *file = fopen("C:\\IridiumPrerequisites\\status.txt", "w");
    if (!file) return; /* Status reporting must not change installer exit handling. */
    if (!strcmp(phase, "installer")) fprintf(file, "%s %u %u %u %u\n", phase, run, runs, process, processes);
    else fprintf(file, "%s\n", phase);
    fclose(file);
}
static BOOL cancelled(void)
{
    return GetFileAttributesW(L"C:\\IridiumPrerequisites\\cancel.flag") != INVALID_FILE_ATTRIBUTES;
}

static BOOL field(const wchar_t *section, const wchar_t *key_name, wchar_t *value)
{
    DWORD size = GetPrivateProfileStringW(section, key_name, L"", value, CAP, config);
    /* Sentinels preserve quotes and leading/trailing whitespace in INI values. */
    if (size < 2 || size == CAP - 1 || value[0] != L'x' || value[size - 1] != L'x') return FALSE;
    memmove(value, value + 1, (size - 2) * sizeof(*value));
    value[size - 2] = 0;
    return TRUE;
}

static DWORD services_start(void)
{
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (manager) { CloseServiceHandle(manager); return 0; }
    DWORD first = GetLastError();
    if (first != RPC_S_SERVER_UNAVAILABLE) return first;
    /* services.exe signals this event when its svcctl RPC endpoint is ready.
     * Reuse an existing start instead of spawning a second service manager.
     */
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, L"__wine_SvcctlStartedEvent");
    if (!event) return GetLastError();
    BOOL other = GetLastError() == ERROR_ALREADY_EXISTS;
    PROCESS_INFORMATION process = {0};
    DWORD error = ERROR_TIMEOUT;
    if (!other) {
        STARTUPINFOW startup = {0};
        startup.cb = sizeof(startup);
        if (!GetSystemDirectoryW(directory, CAP - 32)) { error = GetLastError(); goto out; }
        swprintf(executable, CAP, L"%ls\\services.exe", directory);
        if (!CreateProcessW(executable, NULL, NULL, NULL, FALSE, DETACHED_PROCESS,
                            NULL, directory, &startup, &process)) { error = GetLastError(); goto out; }
        CloseHandle(process.hThread);
    }
    ULONGLONG deadline = GetTickCount64() + 30000;
    do {
        if (cancelled()) { error = ERROR_CANCELLED; break; }
        manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
        if (manager) { CloseServiceHandle(manager); error = 0; break; }
        DWORD rpc = GetLastError();
        if (rpc != RPC_S_SERVER_UNAVAILABLE && rpc != RPC_S_SERVER_TOO_BUSY) { error = rpc; break; }
        if (process.hProcess && WaitForSingleObject(process.hProcess, 0) == WAIT_OBJECT_0) {
            error = ERROR_PROCESS_ABORTED; break;
        }
        /* The event alone is insufficient on the iOS port: also probe RPC. */
        Sleep(100);
    } while (GetTickCount64() < deadline);
out:
    if (process.hProcess) {
        if (error) { TerminateProcess(process.hProcess, error); WaitForSingleObject(process.hProcess, 5000); }
        CloseHandle(process.hProcess);
    }
    CloseHandle(event);
    return error;
}

static BOOL installed(DWORD code) { return code == 0 || code == 3010 || code == 1641; }

static DWORD run_process(DWORD timeout, BOOL *exited)
{
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    if (exited) *exited = FALSE;
    if (cancelled()) return ERROR_CANCELLED;
    if (!CreateProcessW(executable, command, NULL, NULL, FALSE, 0, NULL,
                        directory, &startup, &process)) return GetLastError();
    CloseHandle(process.hThread);
    DWORD code = ERROR_PROCESS_ABORTED;
    ULONGLONG deadline = GetTickCount64() + timeout;
    DWORD waited;
    do {
        waited = WaitForSingleObject(process.hProcess, timeout == INFINITE ? INFINITE : 100);
        if (waited != WAIT_TIMEOUT || timeout == INFINITE) break;
        if (cancelled() || GetTickCount64() >= deadline) break;
    } while (TRUE);
    if (waited == WAIT_OBJECT_0) {
        if (!GetExitCodeProcess(process.hProcess, &code)) code = GetLastError();
        else if (exited) *exited = TRUE;
    } else {
        code = cancelled() ? ERROR_CANCELLED : waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
        /* End only this helper's stuck installer, never a host/runtime thread. */
        if (TerminateProcess(process.hProcess, code)) WaitForSingleObject(process.hProcess, 5000);
    }
    CloseHandle(process.hProcess);
    return code;
}

static DWORD record_run(const wchar_t *section)
{
    UINT hive = GetPrivateProfileIntW(section, L"hive", 0, config);
    UINT count = GetPrivateProfileIntW(section, L"keys", 0, config);
    DWORD value = GetPrivateProfileIntW(section, L"value", 0, config);
    if ((hive != 1 && hive != 2) || !count || count > 2 || !value || !field(section, L"name", name))
        return ERROR_INVALID_DATA;
    for (UINT i = 0; i < count; i++) {
        wchar_t key_name[16];
        swprintf(key_name, 16, L"key%u", i);
        if (!field(section, key_name, key)) return ERROR_INVALID_DATA;
        HKEY handle;
        LSTATUS error = RegCreateKeyExW(hive == 1 ? HKEY_LOCAL_MACHINE : HKEY_CURRENT_USER,
            key, 0, NULL, 0, KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_WOW64_64KEY, NULL, &handle, NULL);
        if (error) return error;
        DWORD previous = 0, type = 0, size = sizeof(previous);
        error = RegQueryValueExW(handle, name, NULL, &type, (BYTE *)&previous, &size);
        if (!error && type == REG_DWORD && size == sizeof(previous) && previous >= value) {
            RegCloseKey(handle);
            continue;
        }
        if (!error || error == ERROR_FILE_NOT_FOUND || error == ERROR_MORE_DATA)
            error = RegSetValueExW(handle, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
        if (!error) error = RegFlushKey(handle);
        RegCloseKey(handle);
        if (error) return error;
    }
    return 0;
}

/* Steam client stage. The game's Steam DRM talks to this running, signed-in
 * client exactly as it would on Windows; nothing in the game is changed.
 * Launch flags come from the plan's [steam] section (Swift side). */
#define STEAM_SIGN_IN_TIMEOUT (30u * 60u * 1000u) /* sign-in and Steam Guard are manual */
#define STEAM_SETTLE 5000u   /* let the client finish its own sign-in work first */
#define STEAM_GONE 60000u    /* a self-update restarts steam.exe under a new pid */
#define STEAM_EXIT_WAIT 20000u
static wchar_t steam_executable[CAP], steam_directory[CAP], steam_saved[3][CAP];
static HANDLE steam_process;
static const wchar_t *const steam_identity[] = { L"SteamAppId", L"SteamGameId", L"SteamAppPath" };
static const wchar_t *const steam_images[] = {
    L"steam.exe", L"steamwebhelper.exe", L"steamerrorreporter.exe", L"steamerrorreporter64.exe",
    L"steamservice.exe", L"gameoverlayui.exe", L"gameoverlayui64.exe",
};

static DWORD steam_create(PROCESS_INFORMATION *process)
{
    /* Iridium exports the game's app ID for the game itself. Steam must not
     * start as if it were that game, so it gets the environment without it. */
    STARTUPINFOW startup = {0};
    BOOL had[3];
    DWORD error = 0;
    startup.cb = sizeof(startup);
    for (UINT i = 0; i < 3; i++) {
        DWORD size = GetEnvironmentVariableW(steam_identity[i], steam_saved[i], CAP);
        had[i] = size && size < CAP;
        SetEnvironmentVariableW(steam_identity[i], NULL);
    }
    if (!CreateProcessW(steam_executable, command, NULL, NULL, FALSE, 0, NULL,
                        steam_directory, &startup, process)) error = GetLastError();
    for (UINT i = 0; i < 3; i++)
        if (had[i]) SetEnvironmentVariableW(steam_identity[i], steam_saved[i]);
    return error;
}

/* Steam publishes its pid and the signed-in account (0 until sign-in) here. */
static DWORD steam_active(DWORD *user)
{
    HKEY key;
    DWORD pid = 0, value, type, size;
    *user = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", 0,
                      KEY_QUERY_VALUE, &key)) return 0;
    size = sizeof(value);
    if (!RegQueryValueExW(key, L"pid", NULL, &type, (BYTE *)&value, &size)
        && type == REG_DWORD && size == sizeof(value)) pid = value;
    size = sizeof(value);
    if (!RegQueryValueExW(key, L"ActiveUser", NULL, &type, (BYTE *)&value, &size)
        && type == REG_DWORD && size == sizeof(value)) *user = value;
    RegCloseKey(key);
    return pid;
}

/* A Steam that was ended without exiting leaves its last values behind. */
static void steam_forget_session(void)
{
    HKEY key;
    DWORD zero = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam\\ActiveProcess", 0,
                      KEY_SET_VALUE, &key)) return;
    RegSetValueExW(key, L"ActiveUser", 0, REG_DWORD, (const BYTE *)&zero, sizeof(zero));
    RegSetValueExW(key, L"pid", 0, REG_DWORD, (const BYTE *)&zero, sizeof(zero));
    RegCloseKey(key);
}

static BOOL process_alive(DWORD pid)
{
    HANDLE handle = pid ? OpenProcess(SYNCHRONIZE, FALSE, pid) : NULL;
    if (!handle) return FALSE;
    BOOL alive = WaitForSingleObject(handle, 0) == WAIT_TIMEOUT;
    CloseHandle(handle);
    return alive;
}

/* Count, and optionally end, Steam's processes in this session (or only
 * steam.exe itself). Its helpers keep the session alive, so none may outlive
 * this helper. */
static UINT steam_processes(BOOL end, BOOL client_only)
{
    UINT found = 0;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry;
    entry.dwSize = sizeof(entry);
    for (BOOL more = Process32FirstW(snapshot, &entry); more; more = Process32NextW(snapshot, &entry)) {
        for (UINT i = 0; i < (client_only ? 1 : sizeof(steam_images) / sizeof(*steam_images)); i++) {
            if (_wcsicmp(entry.szExeFile, steam_images[i])) continue;
            found++;
            if (!end) break;
            HANDLE process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, entry.th32ProcessID);
            if (process) {
                if (TerminateProcess(process, ERROR_CANCELLED)) WaitForSingleObject(process, 5000);
                CloseHandle(process);
            }
            break;
        }
    }
    CloseHandle(snapshot);
    return found;
}

static DWORD steam_start(void)
{
    PROCESS_INFORMATION process = {0};
    if (!field(L"steam", L"executable", steam_executable) || !field(L"steam", L"command", command)
        || !field(L"steam", L"directory", steam_directory)) return ERROR_INVALID_DATA;
    steam_forget_session();
    status("steam", 0, 0, 0, 0);
    fprintf(stderr, "[Prerequisites] Starting Steam: %ls\n", command);
    DWORD error = steam_create(&process);
    if (error) return error;
    CloseHandle(process.hThread);
    steam_process = process.hProcess;
    ULONGLONG start = GetTickCount64(), signed_in = 0, gone = 0;
    BOOL running = FALSE;
    for (;;) {
        if (cancelled()) return ERROR_CANCELLED;
        ULONGLONG now = GetTickCount64();
        DWORD user, pid = steam_active(&user);
        BOOL alive = process_alive(pid);
        if (alive && !running) {
            running = TRUE;
            status("steam-login", 0, 0, 0, 0);
            fprintf(stderr, "[Prerequisites] Steam is running (pid %lu). Waiting for sign-in.\n", pid);
        }
        if (alive && user) {
            if (!signed_in) {
                signed_in = now;
                fprintf(stderr, "[Prerequisites] Steam account signed in.\n");
            } else if (now - signed_in >= STEAM_SETTLE) return 0;
        } else signed_in = 0;
        if (alive || WaitForSingleObject(steam_process, 0) != WAIT_OBJECT_0 || steam_processes(FALSE, TRUE)) gone = 0;
        else if (!gone) gone = now;
        else if (now - gone >= STEAM_GONE) {
            DWORD code = ERROR_PROCESS_ABORTED;
            GetExitCodeProcess(steam_process, &code);
            fprintf(stderr, "[Prerequisites] Steam exited before sign-in: %lu\n", code);
            return code ? code : ERROR_PROCESS_ABORTED;
        }
        if (now - start >= STEAM_SIGN_IN_TIMEOUT) return ERROR_TIMEOUT;
        Sleep(250);
    }
}

/* The process list is the full answer; Steam's own handle covers a session
 * where the list is unavailable. */
static BOOL steam_left(void)
{
    return steam_processes(FALSE, FALSE) || WaitForSingleObject(steam_process, 0) == WAIT_TIMEOUT;
}

static void steam_stop(void)
{
    if (!steam_process) return;
    /* Close (cancel) must finish inside the player's shutdown wait. */
    if (!cancelled() && steam_left()) {
        PROCESS_INFORMATION process = {0};
        status("steam-exit", 0, 0, 0, 0);
        fprintf(stderr, "[Prerequisites] Asking Steam to exit.\n");
        swprintf(command, CAP, L"\"%ls\" -shutdown", steam_executable);
        if (!steam_create(&process)) {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        ULONGLONG deadline = GetTickCount64() + STEAM_EXIT_WAIT;
        while (steam_left() && GetTickCount64() < deadline && !cancelled()) Sleep(250);
    }
    UINT ended = steam_processes(TRUE, FALSE);
    if (ended) fprintf(stderr, "[Prerequisites] Ended %u Steam process(es) still running.\n", ended);
    if (WaitForSingleObject(steam_process, 0) == WAIT_TIMEOUT && TerminateProcess(steam_process, ERROR_CANCELLED))
        WaitForSingleObject(steam_process, 5000);
    CloseHandle(steam_process);
    steam_process = NULL;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc != 2) return ERROR_INVALID_PARAMETER;
    if (cancelled()) return ERROR_CANCELLED;
    config = argv[1];
    UINT runs = GetPrivateProfileIntW(L"plan", L"runs", 0, config);
    UINT use_steam = GetPrivateProfileIntW(L"plan", L"steam", 0, config);
    if (runs > 64 || use_steam > 1 || (!runs && !use_steam)) return ERROR_INVALID_DATA;
    status("services", 0, 0, 0, 0);
    DWORD code = services_start();
    fprintf(stderr, "[Prerequisites] Wine services: %lu\n", code);
    if (code) return code;
    for (UINT i = 0; i < runs; i++) {
        if (cancelled()) return ERROR_CANCELLED;
        wchar_t section[32];
        swprintf(section, 32, L"run%u", i);
        UINT count = GetPrivateProfileIntW(section, L"processes", 0, config);
        if (!count || count > 64) return ERROR_INVALID_DATA;
        for (UINT j = 0; j < count; j++) {
            if (cancelled()) return ERROR_CANCELLED;
            wchar_t step[32];
            swprintf(step, 32, L"process%u_%u", i, j);
            if (!field(step, L"executable", executable) || !field(step, L"command", command)
                || !field(step, L"directory", directory)) return ERROR_INVALID_DATA;
            fprintf(stderr, "[Prerequisites] Running installer %u/%u, process %u/%u\n", i + 1, runs, j + 1, count);
            status("installer", i + 1, runs, j + 1, count);
            BOOL exited;
            code = run_process(600000, &exited);
            fprintf(stderr, "[Prerequisites] Installer %u process %u exited: %lu\n", i + 1, j + 1, code);
            if (!exited || !installed(code)) return code ? code : ERROR_PROCESS_ABORTED;
        }
        /* A shared HasRunKey is complete only after ALL its processes succeed. */
        code = record_run(section);
        if (code) return code;
    }
    if (cancelled()) return ERROR_CANCELLED;
    if (use_steam) {
        code = steam_start();
        fprintf(stderr, "[Prerequisites] Steam client: %lu\n", code);
        if (code) { steam_stop(); return code; }
    }
    if (!field(L"game", L"executable", executable) || !field(L"game", L"command", command)
        || !field(L"game", L"directory", directory)) { steam_stop(); return ERROR_INVALID_DATA; }
    fprintf(stderr, "[Prerequisites] Complete. Starting the selected game.\n");
    status("game", 0, 0, 0, 0);
    code = run_process(INFINITE, NULL);
    steam_stop();
    return code;
}
