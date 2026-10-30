// The storage bus of a drive letter (IOCTL_STORAGE_QUERY_PROPERTY, StorageDeviceProperty): the card watcher offers USB,
// FireWire, SD and MMC disks even when they report DRIVE_FIXED (most USB SSDs do).
#include "csqwinapp.h"
#include <windows.h>
#include <winioctl.h>

int sq_drive_bus_type(const uint16_t *root) {
    // "\\.\E:" from "E:\": no access rights needed for the property query.
    wchar_t path[8] = L"\\\\.\\?:";
    path[4] = static_cast<wchar_t>(root[0]);
    HANDLE h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return -1;
    STORAGE_PROPERTY_QUERY q = {};
    q.PropertyId = StorageDeviceProperty;
    q.QueryType = PropertyStandardQuery;
    STORAGE_DEVICE_DESCRIPTOR d = {};
    DWORD got = 0;
    BOOL ok = DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, sizeof q, &d, sizeof d, &got, nullptr);
    CloseHandle(h);
    return ok && got >= offsetof(STORAGE_DEVICE_DESCRIPTOR, BusType) + sizeof d.BusType ? static_cast<int>(d.BusType) : -1;
}
